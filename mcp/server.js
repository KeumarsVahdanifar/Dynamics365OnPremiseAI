#!/usr/bin/env node
/*
 * Dynamics 365 On-Premise AI Toolkit - MCP server
 *
 * Exposes the toolkit over the Model Context Protocol, so any MCP client (Claude Desktop, an IDE,
 * your own agent) can read and change a Dynamics 365 CE on-premises organisation with the same
 * safety model the CLI has:
 *
 *   - reads are unrestricted and separate from writes;
 *   - a write must be DRY RUN first (d365_plan_write), which returns the confirmation banner
 *     showing exactly what changes and where the backup went;
 *   - only then can d365_apply_write run it, and only with acknowledge:true.
 *
 * The server never sees a password: it shells out to d365.ps1, which uses the DPAPI-encrypted
 * credential cached by `d365.ps1 login` for the signed-in Windows user.
 *
 * Author: Keumars Vahdanifar
 */
'use strict';

const path = require('path');
const { spawn } = require('child_process');
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { z } = require('zod');

const ROOT = path.resolve(__dirname, '..');
const CLI = path.join(ROOT, 'd365.ps1');
const UITEST = path.join(ROOT, 'uitest', 'd365-uitest.ps1');

/* Commands are allow-listed by intent, so a typo or a prompt-injected string cannot turn a read
   into a delete, and a write can never reach the CLI without going through the plan/apply pair. */
const READ_COMMANDS = [
    'whoami', 'version', 'list-entities', 'entity', 'attrs', 'relationships', 'optionsets',
    'global-optionset', 'keys', 'fetch', 'retrieve', 'query', 'count', 'plugin-steps',
    'plugin-assemblies', 'solutions', 'solution-components', 'webresources', 'app-ribbon',
    'entity-ribbon', 'backups', 'config'
];

const WRITE_COMMANDS = [
    'create', 'update', 'delete', 'setstate', 'associate', 'disassociate', 'run-workflow',
    'create-table', 'update-table', 'delete-table',
    'create-column', 'update-column', 'delete-column',
    'create-lookup', 'create-relationship', 'delete-relationship',
    'create-global-optionset', 'delete-global-optionset',
    'insert-option', 'update-option', 'delete-option', 'order-options',
    'create-key', 'create-webresource', 'update-webresource', 'publish-webresource',
    'publish', 'publish-all', 'add-solution-component', 'export-solution', 'import-solution',
    'restore'
];

const MAX_OUTPUT = 60000;

function runCli(args, timeoutMs) {
    return new Promise((resolve) => {
        const full = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', CLI].concat(args);
        const child = spawn('powershell.exe', full, { cwd: ROOT, windowsHide: true });
        let out = '', err = '';
        const timer = setTimeout(() => { try { child.kill(); } catch (e) {} },
                                 timeoutMs || 20 * 60 * 1000);
        child.stdout.on('data', (d) => { out += d.toString('utf8'); });
        child.stderr.on('data', (d) => { err += d.toString('utf8'); });
        child.on('close', (code) => {
            clearTimeout(timer);
            let text = (out + (err ? '\n' + err : '')).trim();
            if (text.length > MAX_OUTPUT) { text = text.slice(0, MAX_OUTPUT) + '\n... (truncated)'; }
            resolve({ code: code, text: text || '(no output)' });
        });
    });
}

/** The session token: the CLI refuses everything until `init` has armed the session. */
function sessionArgs(session) {
    const s = session || process.env.CLAUDE_CODE_SESSION_ID || 'mcp-' + process.pid;
    return ['-Session', s];
}

function optionArgs(o) {
    const a = [];
    if (o.data)     { a.push('-Data', o.data); }
    if (o.columns)  { a.push('-Columns', o.columns); }
    if (o.filter)   { a.push('-Filter', o.filter); }
    if (o.top)      { a.push('-Top', String(o.top)); }
    if (o.out)      { a.push('-Out', o.out); }
    if (o.solution) { a.push('-Solution', o.solution); }
    if (o.managed)  { a.push('-Managed'); }
    if (o.custom)   { a.push('-Custom'); }
    if (o.overwrite){ a.push('-Overwrite'); }
    if (o.url)      { a.push('-Url', o.url); }
    return a;
}

function text(payload) { return { content: [{ type: 'text', text: payload }] }; }

const server = new McpServer({ name: 'Dynamics365OnPremiseAI', version: '2.0.0' });

/* ------------------------------------------------------------------ session ---------------- */

server.registerTool('d365_init', {
    title: 'Initialise the Dynamics 365 session',
    description: 'Connects, runs WhoAmI and arms the session. REQUIRED once before any other tool: ' +
                 'everything else refuses until this has run. Returns the organisation name, URL, ' +
                 'version and user - show that to the operator so it is clear which organisation is ' +
                 'in play.',
    inputSchema: { session: z.string().optional().describe('Session id to arm (defaults to a per-process id)') }
}, async ({ session }) => {
    const r = await runCli(['init'].concat(sessionArgs(session)), 5 * 60 * 1000);
    return text(r.text);
});

/* ------------------------------------------------------------------ reads ------------------- */

server.registerTool('d365_read', {
    title: 'Read from Dynamics 365 (safe)',
    description: 'Runs a read-only toolkit command. Changes nothing. Commands: ' + READ_COMMANDS.join(', ') +
                 '. Examples: {command:"attrs", args:["account"]}, ' +
                 '{command:"fetch", args:["<fetch>...</fetch>"], top:50}, ' +
                 '{command:"optionsets", args:["abc_thing"]}. ' +
                 'Confirm logical names, types and option values with this before writing anything ' +
                 'that depends on them.',
    inputSchema: {
        command: z.string().describe('One of the read commands'),
        args: z.array(z.string()).optional().describe('Positional arguments, e.g. ["account"]'),
        columns: z.string().optional().describe('Comma-separated column list for retrieve/query'),
        filter: z.string().optional().describe('attr=value filter for query'),
        top: z.number().optional().describe('Row limit (default 50; nothing pages)'),
        out: z.string().optional().describe('Write the result to this file (app-ribbon/entity-ribbon)'),
        custom: z.boolean().optional().describe('list-entities: custom entities only'),
        session: z.string().optional()
    }
}, async (o) => {
    if (READ_COMMANDS.indexOf(o.command) === -1) {
        return text('Refused: "' + o.command + '" is not a read command. Reads are limited to: ' +
                    READ_COMMANDS.join(', ') + '. For a change, use d365_plan_write.');
    }
    const args = [o.command].concat(o.args || []).concat(optionArgs(o)).concat(sessionArgs(o.session));
    const r = await runCli(args);
    return text(r.text);
});

/* ------------------------------------------------------------------ writes ------------------ */

server.registerTool('d365_plan_write', {
    title: 'Plan a change (dry run - nothing is modified)',
    description: 'Runs a write command WITHOUT -Yes. Nothing changes. Returns the confirmation ' +
                 'banner: the organisation, what exactly will change (old -> new per column, row ' +
                 'counts for a delete), whether it is reversible, and the local backup path. ' +
                 'ALWAYS call this first and show the banner to the operator - it is how a human ' +
                 'sees what is about to happen. Commands: ' + WRITE_COMMANDS.join(', '),
    inputSchema: {
        command: z.string().describe('One of the write commands'),
        args: z.array(z.string()).optional().describe('Positional arguments, e.g. ["account","<guid>"]'),
        data: z.string().optional().describe('JSON payload, or @C:\\path\\file.json for large or non-ASCII payloads'),
        solution: z.string().optional().describe('Create the component inside this solution instead of Default'),
        out: z.string().optional(),
        managed: z.boolean().optional(),
        overwrite: z.boolean().optional().describe('import-solution: overwrite unmanaged customizations'),
        session: z.string().optional()
    }
}, async (o) => {
    if (WRITE_COMMANDS.indexOf(o.command) === -1) {
        return text('Refused: "' + o.command + '" is not a known write command. Allowed: ' +
                    WRITE_COMMANDS.join(', '));
    }
    const args = [o.command].concat(o.args || []).concat(optionArgs(o)).concat(sessionArgs(o.session));
    const r = await runCli(args);
    return text('DRY RUN - nothing was modified.\n\n' + r.text +
                '\n\nTo execute exactly this, call d365_apply_write with the same arguments and ' +
                'acknowledge:true, after the operator has agreed.');
});

server.registerTool('d365_apply_write', {
    title: 'Apply a change (modifies the live organisation)',
    description: 'Runs the same write command WITH -Yes, which executes it against the live ' +
                 'organisation. The current state is backed up locally first (see d365_backups and ' +
                 'd365_restore). Requires acknowledge:true, and requires that you have already run ' +
                 'd365_plan_write for this change and had the operator agree to it. Never call this ' +
                 'to "try" something.',
    inputSchema: {
        command: z.string(),
        args: z.array(z.string()).optional(),
        data: z.string().optional(),
        solution: z.string().optional(),
        out: z.string().optional(),
        managed: z.boolean().optional(),
        overwrite: z.boolean().optional(),
        acknowledge: z.boolean().describe('Must be true: confirms a dry run was shown and approved'),
        session: z.string().optional()
    }
}, async (o) => {
    if (WRITE_COMMANDS.indexOf(o.command) === -1) {
        return text('Refused: "' + o.command + '" is not a known write command.');
    }
    if (o.acknowledge !== true) {
        return text('Refused: acknowledge must be true. Run d365_plan_write, show the banner to the ' +
                    'operator, get agreement, then call this with acknowledge:true.');
    }
    const args = [o.command].concat(o.args || []).concat(optionArgs(o))
                            .concat(['-Yes']).concat(sessionArgs(o.session));
    const r = await runCli(args);
    return text(r.text);
});

/* ------------------------------------------------------------------ undo -------------------- */

server.registerTool('d365_backups', {
    title: 'List local backups',
    description: 'Lists what the toolkit captured before each change: time, kind, target, the command ' +
                 'that caused it, and the file to pass to d365_restore.',
    inputSchema: {
        filter: z.string().optional().describe('Match a target name or a kind (record, webresource, metadata, solution)'),
        top: z.number().optional().describe('How many of the most recent to list (default 25)'),
        session: z.string().optional()
    }
}, async (o) => {
    const args = ['backups'].concat(o.filter ? [o.filter] : [])
                            .concat(o.top ? ['-Top', String(o.top)] : [])
                            .concat(sessionArgs(o.session));
    const r = await runCli(args);
    return text(r.text);
});

server.registerTool('d365_restore', {
    title: 'Restore from a backup',
    description: 'Puts a captured state back: a record\'s column values, a web resource\'s previous ' +
                 'content (and republishes it), or a solution export (re-imported). Call without ' +
                 'apply:true first to see exactly what would be written. Schema and choice deletes ' +
                 'are documented but cannot be undone this way.',
    inputSchema: {
        file: z.string().describe('Backup file path from d365_backups'),
        apply: z.boolean().optional().describe('true to actually restore; omit for a dry run'),
        session: z.string().optional()
    }
}, async (o) => {
    const args = ['restore', o.file].concat(o.apply === true ? ['-Yes'] : []).concat(sessionArgs(o.session));
    const r = await runCli(args);
    return text((o.apply === true ? '' : 'DRY RUN - nothing was restored.\n\n') + r.text);
});

/* ------------------------------------------------------------------ UI verification --------- */

server.registerTool('d365_uitest', {
    title: 'Verify the UI in a real browser',
    description: 'Drives an installed Chrome or Edge against the organisation and returns JSON: check ' +
                 'results, browser console errors with URLs, failed requests and screenshot paths. Use ' +
                 'it after any change a user is meant to SEE - the SDK cannot tell you whether a ' +
                 'ribbon button drew, a script threw, or a web resource 404d. Check modules live in ' +
                 'uitest/checks (smoke.js, probe-header.js, record-form.js, view-grid.js, ' +
                 'ribbon-badge.js).',
    inputSchema: {
        check: z.string().optional().describe('Check module, e.g. checks/smoke.js'),
        app: z.string().optional().describe('Unified Interface app id (appid)'),
        classic: z.boolean().optional().describe('Drive the classic web client instead'),
        goto: z.string().optional().describe('Relative URL to open, e.g. main.aspx?etn=account&pagetype=entitylist'),
        settleMs: z.number().optional().describe('How long to let the shell settle (default 9000)'),
        out: z.string().optional().describe('Directory for screenshots')
    }
}, async (o) => {
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', UITEST];
    if (o.check)    { args.push('-Check', o.check); }
    if (o.app)      { args.push('-App', o.app); }
    if (o.classic)  { args.push('-Classic'); }
    if (o.goto)     { args.push('-Goto', o.goto); }
    if (o.settleMs) { args.push('-Settle', String(o.settleMs)); }
    if (o.out)      { args.push('-Out', o.out); }
    return new Promise((resolve) => {
        const child = spawn('powershell.exe', args, { cwd: ROOT, windowsHide: true });
        let out = '', err = '';
        const timer = setTimeout(() => { try { child.kill(); } catch (e) {} }, 15 * 60 * 1000);
        child.stdout.on('data', (d) => { out += d.toString('utf8'); });
        child.stderr.on('data', (d) => { err += d.toString('utf8'); });
        child.on('close', () => {
            clearTimeout(timer);
            let t = (out + (err ? '\n' + err : '')).trim();
            if (t.length > MAX_OUTPUT) { t = t.slice(0, MAX_OUTPUT) + '\n... (truncated)'; }
            resolve(text(t || '(no output)'));
        });
    });
});

/* ------------------------------------------------------------------ guidance ---------------- */

server.registerTool('d365_safety_rules', {
    title: 'The rules for working on a live organisation',
    description: 'Returns the working agreement for this toolkit. Read it before your first write in ' +
                 'a session, and follow it.',
    inputSchema: {}
}, async () => text([
    'Dynamics 365 On-Premise AI Toolkit - how to work without breaking an organisation:',
    '',
    '1. d365_init first, every session. Tell the operator which organisation it printed.',
    '2. Read before you write: d365_read (attrs / optionsets / entity / count) to confirm logical',
    '   names, types and option values. Never write against a remembered schema.',
    '3. Every change: d365_plan_write, show the operator the banner (it states the organisation, the',
    '   old -> new values, reversibility and the backup path), get agreement, then d365_apply_write',
    '   with acknowledge:true. One change at a time.',
    '4. Deletes of tables, columns, relationships and choice options destroy data and CANNOT be',
    '   undone by d365_restore. Say so out loud before proposing one, and prefer an alternative.',
    '5. A logical name can never be renamed. Get names right the first time.',
    '6. Keep a feature in one solution: pass solution:"<uniquename>" when creating components.',
    '7. Publish what you changed (publish <entity>), not publish-all on a busy organisation.',
    '8. Verify anything a user should see with d365_uitest, and report console errors it finds.',
    '9. If something went wrong: stop, d365_backups, d365_restore. Do not fix forward with more writes.',
    '10. Never print, log or ask for the password. Authentication is the cached Windows credential.'
].join('\n')));

/* ------------------------------------------------------------------ go --------------------- */

(async () => {
    const transport = new StdioServerTransport();
    await server.connect(transport);
})().catch((e) => {
    process.stderr.write('failed to start: ' + (e && e.stack || e) + '\n');
    process.exit(1);
});

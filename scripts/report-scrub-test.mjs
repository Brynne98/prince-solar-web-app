#!/usr/bin/env node
/**
 * What public/config.js lets out to PostHog (SOLAR-533). Runs the real file as the live
 * site would, with a fake PostHog, and fails if an address keeps its query or #hash, or
 * if database error text goes out unmasked. Run by `npm test`; exit 1 on a failure.
 */
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

let opts; const sent = [];
const posthog = {
  init: (key, o) => { opts = o; }, register() {}, capture() {}, get_distinct_id() {},
  captureException: (err, props) => { sent.push({ err, props }); return { uuid: 'id-1' }; },
};
const window = { posthog, addEventListener() {} };
vm.runInNewContext(fs.readFileSync(new URL('../public/config.js', import.meta.url), 'utf8'), {
  window, localStorage: { getItem: () => null },
  location: { hostname: 'app.princesolarhub.co.za', pathname: '/', search: '?reference=psh_abc123&plant=495944' },
});

// every address on an event: host and path only
const ev = opts.before_send({
  event: 'screen_viewed',
  properties: {
    $current_url: 'https://app.princesolarhub.co.za/?reference=psh_abc123&plant=495944#access_token=tok',
    $referrer: 'https://princesolarhub.co.za/welcome?signup', screen: 'live', plant_id: 495944,
    $set_once: { $initial_current_url: 'https://app.princesolarhub.co.za/?plant=495944' },
  },
  $set: { $current_url: 'https://app.princesolarhub.co.za/?pay=1' },
});
assert.equal(ev.properties.$current_url, 'https://app.princesolarhub.co.za/');
assert.equal(ev.properties.$referrer, 'https://princesolarhub.co.za/welcome');
assert.equal(ev.properties.$set_once.$initial_current_url, 'https://app.princesolarhub.co.za/');
assert.equal(ev.$set.$current_url, 'https://app.princesolarhub.co.za/');
assert.equal(ev.properties.plant_id, 495944); // not an address: untouched
assert.ok(!/psh_abc123|access_token|[?#]/.test(JSON.stringify(ev)));

// an error message: email masked, an address inside it cut
const ex = opts.before_send({ event: '$exception', properties: { $exception_list: [
  { value: 'Failed for sam@example.com at https://app.princesolarhub.co.za/?reference=psh_abc123 now' }] } });
assert.equal(ex.properties.$exception_list[0].value, 'Failed for [email] at https://app.princesolarhub.co.za/ now');

// a database error: its code and a short masked message; the page has no query
window.reportServerError('api_overview',
  { code: '42703', message: 'column "secret_col" of relation "plants" (id)=(495944) for sam@example.com does not exist ' + 'x'.repeat(200) }, 400);
assert.equal(sent.length, 1);
const msg = sent[0].err.message;
assert.ok(msg.startsWith('api_overview: 42703 '), msg);
assert.ok(!/secret_col|plants|495944|sam@/.test(msg), msg);
assert.ok(msg.length <= 'api_overview: 42703 '.length + 80, msg);
assert.equal(sent[0].props.page, '/');

// 42501 (SOLAR-536): a deliberate refusal and a signed-out call stay unsent; a missing table right is sent
window.reportServerError('api_me', { code: '42501', message: 'permission denied for function api_me' }, 401);
window.reportServerError('api_overview', { code: '42501', message: 'not linked' }, 403);
window.reportServerError('api_plant_pick', { code: '42501', message: 'sign in first' }, 403);
assert.equal(sent.length, 1);
window.reportServerError('plant_config', { code: '42501', message: 'permission denied for table plant_config' }, 403);
assert.equal(sent.length, 2);
assert.ok(sent[1].err.message.startsWith('plant_config: 42501 permission denied for table'), sent[1].err.message);
assert.equal(sent[1].props.$exception_fingerprint, 'rpc:plant_config:42501');

// the bot check key: none off a local host until the live one is filled in, or the live one
assert.ok(window.TURNSTILE_SITE_KEY !== '1x00000000000000000000AA');
console.log('report-scrub-test: ok');

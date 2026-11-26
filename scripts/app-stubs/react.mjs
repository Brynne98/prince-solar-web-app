// React for the node tests (scripts/app-modules.mjs): each name calls globalThis.reactStub's,
// else does nothing. Functions, so a module may destructure them or extend Component on load.
import { stub } from '../app-modules.mjs';
const React = new Proxy({}, { get: (t, k) => function (...a) { return (globalThis.reactStub?.[k] || stub())(...a); } });
export default React;

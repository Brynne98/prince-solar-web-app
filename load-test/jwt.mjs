// HS256 token for the local PostgREST: node load-test/jwt.mjs <secret> <role> [sub]
import { createHmac } from "node:crypto";
const [secret, role, sub] = process.argv.slice(2);
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const body = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({ role, ...(sub ? { sub } : {}), exp: 4102444800 })}`;
console.log(`${body}.${createHmac("sha256", secret).update(body).digest("base64url")}`);

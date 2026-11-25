// Replace the load-test fleet in the LOCAL database: lt3.clear(), then lt3.load(fleet(shape)).
//   npx deno@2.5.6 run -A --node-modules-dir=none load-test/v3/load.ts <shape> <db url>
import postgres from "npm:postgres@3.4.5";
import { fleet } from "./fleet.mjs";
const [shape, url] = Deno.args;
if (!/127\.0\.0\.1|localhost/.test(url)) throw new Error("local databases only");
const sql = postgres(url, { max: 1, onnotice: () => {} });
await sql.unsafe(await Deno.readTextFile(new URL("./fleet.sql", import.meta.url)));
await sql`select lt3.clear()`;
await sql`truncate lt3.expected`;
const [r] = await sql`select lt3.load(${JSON.stringify(fleet(shape))}::text::jsonb) as routes`;
console.log(`fleet ${shape}: ${r.routes} routes`);
await sql.end();

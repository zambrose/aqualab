// Validates all fixture traces (and any path passed as argv) against trace.schema.json.
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const schema = JSON.parse(readFileSync(join(root, 'fixtures/trace.schema.json'), 'utf8'));
const ajv = new Ajv({ allErrors: true, strict: false });
const validate = ajv.compile(schema);

const targets = process.argv.length > 2
  ? process.argv.slice(2)
  : readdirSync(join(root, 'fixtures'))
      .filter((f) => f.endsWith('.fixture.json'))
      .map((f) => join(root, 'fixtures', f));

let failed = false;
for (const file of targets) {
  const trace = JSON.parse(readFileSync(file, 'utf8'));
  if (validate(trace)) {
    console.log(`ok   ${file}`);
  } else {
    failed = true;
    console.error(`FAIL ${file}`);
    for (const err of validate.errors) console.error(`  ${err.instancePath} ${err.message}`);
  }
}
process.exit(failed ? 1 : 0);

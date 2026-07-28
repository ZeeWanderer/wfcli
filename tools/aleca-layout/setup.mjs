import path from "node:path";
import { fileURLToPath } from "node:url";

import { prepareAlecaSource } from "./source.mjs";

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolDirectory, "../..");
const source = process.argv[2] ?? process.env.ALECA_LAYOUT_SOURCE;
const prepared = await prepareAlecaSource(repositoryRoot, source);

process.stdout.write(`AlecaFrame ${prepared.version}: ${prepared.path}\n`);

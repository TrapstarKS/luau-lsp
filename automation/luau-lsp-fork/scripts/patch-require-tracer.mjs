#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const tracerPath = path.resolve(
	process.cwd(),
	args.file ?? 'luau/Analysis/src/RequireTracer.cpp'
);
const functions = uniqueFunctions(args.functions ?? 'sharedRequire');

if (!fs.existsSync(tracerPath)) {
	console.error(`[patch] File not found: ${tracerPath}`);
	process.exit(1);
}

const source = fs.readFileSync(tracerPath, 'utf8');
const patched = patchRequireTracer(source, functions);

if (patched === source) {
	console.log('[patch] No changes applied (already patched or pattern not found).');
	process.exit(0);
}

fs.writeFileSync(tracerPath, patched, 'utf8');
console.log(`[patch] Applied require-like patch for: ${['require', ...functions].join(', ')}`);

function patchRequireTracer(content, extraFunctions) {
	const names = ['require', ...extraFunctions];
	const condition = names.map((name) => `global->name == "${name}"`).join(' || ');

	const beforePattern =
		/if\s*\(\s*global\s*&&\s*global->name\s*==\s*"require"\s*&&\s*expr->args\.size\s*>=\s*1\s*\)\s*\n\s*requireCalls\.push_back\(expr\);\n/;

	if (beforePattern.test(content)) {
		const replacement =
			`if (global && expr->args.size >= 1 && (${condition}))\n` +
			`            requireCalls.push_back(expr);\n`;
		return content.replace(beforePattern, replacement);
	}

	const existingRequireLike =
		/if\s*\(\s*global\s*&&\s*expr->args\.size\s*>=\s*1\s*&&\s*\(([^)]+)\)\s*\)\s*\n\s*requireCalls\.push_back\(expr\);\n/;
	const match = content.match(existingRequireLike);
	if (!match) {
		throw new Error(
			'[patch] Could not find expected require-tracing condition. Upstream layout changed.'
		);
	}

	const currentCondition = match[1];
	const requiredChecks = names
		.map((name) => `global->name == "${name}"`)
		.filter((check) => !currentCondition.includes(check));

	if (requiredChecks.length === 0) {
		return content;
	}

	const mergedCondition = `${currentCondition} || ${requiredChecks.join(' || ')}`;
	return content.replace(existingRequireLike, (all) =>
		all.replace(currentCondition, mergedCondition)
	);
}

function parseArgs(argv) {
	const result = {};
	for (let i = 0; i < argv.length; i += 1) {
		const arg = argv[i];
		if (arg === '--file') {
			result.file = argv[i + 1];
			i += 1;
			continue;
		}
		if (arg === '--functions') {
			result.functions = argv[i + 1];
			i += 1;
			continue;
		}
	}
	return result;
}

function uniqueFunctions(csv) {
	return [...new Set(csv.split(',').map((item) => item.trim()).filter(Boolean))]
		.filter((name) => name !== 'require');
}

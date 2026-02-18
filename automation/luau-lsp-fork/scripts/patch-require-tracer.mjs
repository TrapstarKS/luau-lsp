#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const luauRoot = path.resolve(process.cwd(), args.luauRoot ?? 'luau');
const functions = uniqueFunctions(args.functions ?? 'sharedRequire');

if (!fs.existsSync(luauRoot)) {
	console.error(`[patch] Luau root not found: ${luauRoot}`);
	process.exit(1);
}

const targetChecks = functions.map((name) => `funcAsGlobal->name != "${name}"`);
const targetChecksLinter = functions.map((name) => `glob->name == "${name}"`);

const replacements = [
	{
		relativePath: 'Analysis/src/RequireTracer.cpp',
		pattern:
			/if\s*\(\s*global\s*&&\s*global->name\s*==\s*"require"\s*&&\s*expr->args\.size\s*>=\s*1\s*\)\s*\n\s*requireCalls\.push_back\(expr\);\n/,
		buildReplacement: (matchIndent) => {
			const condition = ['global->name == "require"', ...functions.map((name) => `global->name == "${name}"`)].join(' || ');
			return (
				`${matchIndent}if (global && expr->args.size >= 1 && (${condition}))\n` +
				`${matchIndent}    requireCalls.push_back(expr);\n`
			);
		},
		mergePattern:
			/if\s*\(\s*global\s*&&\s*expr->args\.size\s*>=\s*1\s*&&\s*\(([^)]+)\)\s*\)\s*\n\s*requireCalls\.push_back\(expr\);\n/
	},
	{
		relativePath: 'Analysis/src/ConstraintGenerator.cpp',
		pattern: /if\s*\(!funcAsGlobal\s*\|\|\s*funcAsGlobal->name\s*!=\s*require\)\s*\n\s*return std::nullopt;\n/,
		buildReplacement: (matchIndent) => {
			const condition = targetChecks.join(' && ');
			return (
				`${matchIndent}if (!funcAsGlobal || (funcAsGlobal->name != require && ${condition}))\n` +
				`${matchIndent}    return std::nullopt;\n`
			);
		}
	},
	{
		relativePath: 'Analysis/src/TypeInfer.cpp',
		pattern: /if\s*\(!funcAsGlobal\s*\|\|\s*funcAsGlobal->name\s*!=\s*require\)\s*\n\s*return std::nullopt;\n/,
		buildReplacement: (matchIndent) => {
			const condition = targetChecks.join(' && ');
			return (
				`${matchIndent}if (!funcAsGlobal || (funcAsGlobal->name != require && ${condition}))\n` +
				`${matchIndent}    return std::nullopt;\n`
			);
		}
	},
	{
		relativePath: 'Analysis/src/Linter.cpp',
		pattern: /return glob->name == "require";\n/,
		buildReplacement: () => {
			const condition = ['glob->name == "require"', ...targetChecksLinter].join(' || ');
			return `return ${condition};\n`;
		}
	}
];

let filesChanged = 0;

for (const replacement of replacements) {
	const filePath = path.join(luauRoot, replacement.relativePath);
	if (!fs.existsSync(filePath)) {
		throw new Error(`[patch] File not found: ${filePath}`);
	}

	const source = fs.readFileSync(filePath, 'utf8');
	const patched = patchContent(source, replacement);
	if (patched !== source) {
		fs.writeFileSync(filePath, patched, 'utf8');
		filesChanged += 1;
	}
}

if (filesChanged === 0) {
	console.log('[patch] No changes applied (already patched).');
	process.exit(0);
}

console.log(`[patch] Applied require-like patch for: ${['require', ...functions].join(', ')}`);
console.log(`[patch] Updated files: ${filesChanged}`);

function patchContent(content, replacement) {
	if (replacement.pattern.test(content)) {
		return content.replace(replacement.pattern, (fullMatch) => {
			const indent = fullMatch.match(/^(\s*)/)?.[1] ?? '';
			return replacement.buildReplacement(indent);
		});
	}

	if (replacement.mergePattern) {
		const match = content.match(replacement.mergePattern);
		if (!match) {
			throw new Error(
				`[patch] Could not find expected pattern in ${replacement.relativePath}. Upstream layout changed.`
			);
		}

		const currentCondition = match[1];
		const requiredChecks = functions
			.map((name) => `global->name == "${name}"`)
			.filter((check) => !currentCondition.includes(check));

		if (requiredChecks.length === 0) {
			return content;
		}

		const mergedCondition = `${currentCondition} || ${requiredChecks.join(' || ')}`;
		return content.replace(replacement.mergePattern, (all) =>
			all.replace(currentCondition, mergedCondition)
		);
	}

	if (isAlreadyPatched(content, replacement.relativePath)) {
		return content;
	}

	throw new Error(
		`[patch] Could not find expected pattern in ${replacement.relativePath}. Upstream layout changed.`
	);
}

function isAlreadyPatched(content, relativePath) {
	const checks = {
		'Analysis/src/RequireTracer.cpp': [
			'global->name == "require"',
			...functions.map((name) => `global->name == "${name}"`)
		],
		'Analysis/src/ConstraintGenerator.cpp': [
			'funcAsGlobal->name != require',
			...functions.map((name) => `funcAsGlobal->name != "${name}"`)
		],
		'Analysis/src/TypeInfer.cpp': [
			'funcAsGlobal->name != require',
			...functions.map((name) => `funcAsGlobal->name != "${name}"`)
		],
		'Analysis/src/Linter.cpp': ['glob->name == "require"', ...functions.map((name) => `glob->name == "${name}"`)]
	};

	const requiredTokens = checks[relativePath];
	if (!requiredTokens) {
		return false;
	}

	return requiredTokens.every((token) => content.includes(token));
}

function parseArgs(argv) {
	const result = {};
	for (let i = 0; i < argv.length; i += 1) {
		const arg = argv[i];
		if (arg === '--file') {
			// Backward compatibility; ignored now.
			result.file = argv[i + 1];
			i += 1;
			continue;
		}
		if (arg === '--luau-root') {
			result.luauRoot = argv[i + 1];
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

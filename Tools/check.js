// kkowoUI 严格静态检查器（基于 luaparse）
// 检查：1) 语法正确性 2) 零未声明全局写入 3) 零先用后声明 local
//       4) 禁止向暴雪核心全局框体表写字段 5) 顶层 local 数量上限
//       6) 禁止读取未声明的 math_*/string_*/table_*/bit_* 本地别名
//       7) 禁止 x and not F.IsSecret(x) 倒置机密值判断顺序
'use strict';

const fs = require('fs');
const path = require('path');

let luaparse;
const candidates = [
  path.join(__dirname, 'node_modules', 'luaparse'),
  process.env.LUAPARSE_PATH || '',
  // 兄弟仓库里已安装的 luaparse（相对仓库上级目录，不写死盘符）
  path.join(__dirname, '..', '..', 'haaland', 'tools', 'node_modules', 'luaparse'),
  path.join(__dirname, '..', '..', 'kkowo', 'tools', 'node_modules', 'luaparse'),
  'luaparse',
].filter(Boolean);
for (const c of candidates) {
  try {
    luaparse = require(c);
    break;
  } catch (_) {}
}
if (!luaparse) {
  console.error('找不到 luaparse，请在 Tools 目录运行 npm install luaparse');
  process.exit(2);
}

const ADDON_BASE = path.join(__dirname, '..', 'Addon');
const ALLOWED_GLOBALS = new Set([
  'kkowoUI',
  'kkowoUIDB',
  'kkowoUICharDB',
  'kkowoUIRecordDB',
  // 改名前的旧存档变量（DB.Init 里搬到新名字后清空）
  'KkowoUIDB',
  'KkowoUICharDB',
  'SlashCmdList',
  // GroundPin 快捷键绑定（Bindings.xml 明确规定的 5 个全局符号）
  'BINDING_HEADER_KKOWOUI_NAV',
  'BINDING_NAME_KKOWOUI_GROUNDPIN',
  'BINDING_NAME_KKOWOUI_GROUNDPIN_CLEAR',
  'kkowoUI_GroundPin_OnKey',
  'kkowoUI_GroundPin_Clear',
]);
const ALLOWED_GLOBAL_PREFIXES = [
  'SLASH_',
  'BINDING_HEADER_KKOWOUI_',
  'BINDING_NAME_KKOWOUI_',
];
const LOCAL_STDLIB_ALIAS_RE = /^(?:math|string|table|bit)_[A-Za-z0-9_]+$/;
function isAllowedGlobal(name) {
  if (ALLOWED_GLOBALS.has(name)) return true;
  for (const p of ALLOWED_GLOBAL_PREFIXES) {
    if (name.startsWith(p)) return true;
  }
  return false;
}
function exprKey(node) {
  if (!node) return null;
  if (node.type === 'Identifier') return node.name;
  if (node.type === 'MemberExpression' && node.indexer === '.' && node.identifier && node.identifier.type === 'Identifier') {
    const base = exprKey(node.base);
    return base ? `${base}.${node.identifier.name}` : null;
  }
  return null;
}
function getIsSecretArg(node) {
  // 匹配 not F.IsSecret(x) / not issecretvalue(x) / not IsSecret(x)
  if (!node || node.type !== 'UnaryExpression' || node.operator !== 'not') return null;
  const call = node.argument;
  if (!call || call.type !== 'CallExpression' || !call.arguments || call.arguments.length !== 1) return null;
  const base = call.base;
  let isSecretCall = false;
  if (base && base.type === 'Identifier' && (base.name === 'IsSecret' || base.name === 'issecretvalue')) {
    isSecretCall = true;
  } else if (base && base.type === 'MemberExpression' && base.identifier && base.identifier.type === 'Identifier') {
    if (base.identifier.name === 'IsSecret' || base.identifier.name === 'issecretvalue') {
      isSecretCall = true;
    }
  }
  if (!isSecretCall) return null;
  return exprKey(call.arguments[0]);
}
function testsTargetBeforeSecret(node, targetKey) {
  if (!node || !targetKey) return false;
  if (exprKey(node) === targetKey) return true;
  if (node.type === 'UnaryExpression' && (node.operator === 'not' || node.operator === '#')) {
    return exprKey(node.argument) === targetKey;
  }
  if (node.type === 'BinaryExpression') {
    return exprKey(node.left) === targetKey || exprKey(node.right) === targetKey;
  }
  return false;
}
function flattenAndChain(node, out = []) {
  if (node && node.type === 'LogicalExpression' && node.operator === 'and') {
    flattenAndChain(node.left, out);
    flattenAndChain(node.right, out);
  } else if (node) {
    out.push(node);
  }
  return out;
}
const FORBIDDEN_BLIZZ_WRITES = new Set([
  'WorldMapFrame',
  'SuperTrackedFrame',
  'GameTooltip',
  'CharacterFrame',
  'MacroFrame',
  'BuffFrame',
  'DebuffFrame',
  'C_AddOnProfiler',
]);

function walkLua(dir, out = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      // 跳过 MIT 原样内嵌的第三方上游源码目录（如 kkowoUI_Tooltip/Vendor）
      if (ent.name === 'Vendor') continue;
      walkLua(full, out);
    } else if (ent.name.endsWith('.lua')) {
      out.push(full);
    }
  }
  return out;
}

function collectAddonFiles() {
  const out = [];
  for (const ent of fs.readdirSync(ADDON_BASE, { withFileTypes: true })) {
    if (ent.isDirectory() && ent.name.startsWith('kkowoUI')) {
      walkLua(path.join(ADDON_BASE, ent.name), out);
    }
  }
  return out.sort();
}

function checkFile(filePath) {
  const rel = path.relative(ADDON_BASE, filePath);
  const src = fs.readFileSync(filePath, 'utf8');
  const errors = [];
  const warnings = [];
  let ast;
  try {
    ast = luaparse.parse(src, { luaVersion: '5.1', locations: true, scope: true });
  } catch (e) {
    errors.push(`${rel}: 语法错误 ${e.message}`);
    return { errors, warnings };
  }

  // 收集文件顶层 local 声明及其首次出现行号
  const topLocals = new Map();
  let topLocalCount = 0;

  for (const stmt of ast.body) {
    if (stmt.type === 'LocalStatement') {
      for (const v of stmt.variables) {
        topLocalCount++;
        if (!topLocals.has(v.name)) topLocals.set(v.name, v.loc.start.line);
      }
    } else if (stmt.type === 'FunctionDeclaration' && stmt.isLocal && stmt.identifier) {
      topLocalCount++;
      if (!topLocals.has(stmt.identifier.name)) topLocals.set(stmt.identifier.name, stmt.loc.start.line);
    }
  }
  if (topLocalCount > 150) {
    warnings.push(`${rel}: 顶层 local 达到 ${topLocalCount} 个（建议 < 150，Lua 上限 200）`);
  }

  const scopes = [new Set()];
  const hasLocal = (name) => {
    for (let i = scopes.length - 1; i >= 0; i--) {
      if (scopes[i].has(name)) return true;
    }
    return false;
  };
  const declareLocal = (name) => scopes[scopes.length - 1].add(name);

  function visit(node) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const item of node) visit(item);
      return;
    }

    switch (node.type) {
      case 'LocalStatement':
        // 先检查 init，再声明 variables
        visit(node.init);
        for (const v of node.variables) declareLocal(v.name);
        return;

      case 'FunctionDeclaration': {
        if (node.isLocal && node.identifier) {
          declareLocal(node.identifier.name);
        } else if (!node.isLocal && node.identifier) {
          if (node.identifier.type === 'Identifier') {
            const n = node.identifier.name;
            if (!hasLocal(n) && !isAllowedGlobal(n)) {
              errors.push(`${rel}:${node.loc.start.line}: 声明了全局函数 ${n}`);
            }
          }
        }
        scopes.push(new Set());
        if (node.identifier && node.identifier.type === 'MemberExpression' && node.identifier.indexer === ':') {
          declareLocal('self');
        }
        for (const p of node.parameters || []) {
          if (p.type === 'Identifier') declareLocal(p.name);
        }
        visit(node.body);
        scopes.pop();
        return;
      }

      case 'AssignmentStatement': {
        for (const v of node.variables) {
          if (v.type === 'Identifier') {
            const n = v.name;
            if (!hasLocal(n) && !isAllowedGlobal(n)) {
              errors.push(`${rel}:${v.loc.start.line}: 写入全局变量 ${n}`);
            }
          } else if (v.type === 'MemberExpression' || v.type === 'IndexExpression') {
            let base = v.base;
            while (base && (base.type === 'MemberExpression' || base.type === 'IndexExpression')) {
              base = base.base;
            }
            if (base && base.type === 'Identifier' && FORBIDDEN_BLIZZ_WRITES.has(base.name)) {
              errors.push(`${rel}:${v.loc.start.line}: 禁止直接向暴雪全局框体/表 ${base.name} 写字段`);
            }
            visit(v);
          }
        }
        visit(node.init);
        return;
      }

      case 'ForNumericStatement':
        visit(node.start); visit(node.end); visit(node.step);
        scopes.push(new Set([node.variable.name]));
        visit(node.body);
        scopes.pop();
        return;

      case 'ForGenericStatement':
        visit(node.iterators);
        scopes.push(new Set(node.variables.map((v) => v.name)));
        visit(node.body);
        scopes.pop();
        return;

      case 'DoStatement':
      case 'WhileStatement':
      case 'IfClause':
      case 'ElseifClause':
      case 'ElseClause':
        scopes.push(new Set());
        visit(node.condition);
        visit(node.body);
        scopes.pop();
        return;

      case 'RepeatStatement':
        scopes.push(new Set());
        visit(node.body);
        visit(node.condition);
        scopes.pop();
        return;

      case 'LogicalExpression': {
        if (node.operator === 'and') {
          const chain = flattenAndChain(node);
          for (let j = 1; j < chain.length; j++) {
            const targetKey = getIsSecretArg(chain[j]);
            if (targetKey) {
              for (let i = 0; i < j; i++) {
                if (testsTargetBeforeSecret(chain[i], targetKey)) {
                  errors.push(`${rel}:${chain[j].loc.start.line}: 机密值判断顺序倒置，应先判 not F.IsSecret(${targetKey}) 再判 ${targetKey}`);
                  break;
                }
              }
            }
          }
          // 遍历叶子节点，避免同一条 and 链在子节点上重复报错
          for (const item of chain) visit(item);
          return;
        }
        visit(node.left);
        visit(node.right);
        return;
      }

      case 'Identifier': {
        const name = node.name;
        if (!hasLocal(name) && topLocals.has(name) && node.loc.start.line < topLocals.get(name)) {
          errors.push(`${rel}:${node.loc.start.line}: 在 local ${name}（第 ${topLocals.get(name)} 行）声明之前使用了它`);
        } else if (!hasLocal(name) && LOCAL_STDLIB_ALIAS_RE.test(name)) {
          errors.push(`${rel}:${node.loc.start.line}: 读取了未声明的本地别名 ${name}`);
        }
        return;
      }

      default:
        for (const k of Object.keys(node)) {
          if (k === 'loc' || k === 'range' || k === 'type' || k === 'isLocal') continue;
          if (node.type === 'MemberExpression' && k === 'identifier') continue;
          if (node.type === 'TableKeyString' && k === 'key') continue;
          visit(node[k]);
        }
    }
  }

  visit(ast.body);
  return { errors, warnings };
}

const files = collectAddonFiles();
let totalErrors = 0;
let totalWarnings = 0;
for (const f of files) {
  const { errors, warnings } = checkFile(f);
  for (const e of errors) { console.error('ERROR', e); totalErrors++; }
  for (const w of warnings) { console.warn('WARN ', w); totalWarnings++; }
}
console.log(`\n检查完成：${files.length} 个 Lua 文件，${totalErrors} 个错误，${totalWarnings} 个警告`);
process.exit(totalErrors > 0 ? 1 : 0);

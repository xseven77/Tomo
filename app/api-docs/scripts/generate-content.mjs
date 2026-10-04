import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {unified} from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
const source=new URL('../../../docs/developer/desktop-api.md',import.meta.url);
const markdown=await readFile(source,'utf8');
const tree=unified().use(remarkParse).use(remarkGfm).parse(markdown);
function text(node){return node.value??node.children?.map(text).join('')??'';}
const ids=new Map();
function slug(title){const base=title.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').trim().replace(/\s+/g,'-')||'section';const n=ids.get(base)||0;ids.set(base,n+1);return n?`${base}-${n}`:base;}
const headings=tree.children.filter(n=>n.type==='heading'&&n.depth<=2);
const sections=headings.map((node,index)=>({id:slug(text(node)),title:text(node),markdown:markdown.slice(node.position.start.offset,headings[index+1]?.position.start.offset??markdown.length)}));
let commit=null;try{commit=execFileSync('git',['rev-parse','HEAD'],{cwd:new URL('../../..',import.meta.url),encoding:'utf8'}).trim();}catch{}
await writeFile(new URL('../app/content.json',import.meta.url),JSON.stringify({title:'Tomo 桌面 API',version:'next',status:'工作区核验版 · 未发布',source:'docs/developer/desktop-api.md',sha256:createHash('sha256').update(markdown).digest('hex'),commit,sections},null,2)+'\n');
console.log(`Generated ${sections.length} sections from canonical API Markdown.`);

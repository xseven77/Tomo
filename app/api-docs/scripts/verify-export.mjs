import assert from 'node:assert/strict';
import {readFile,readdir,lstat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const root=new URL('../out/',import.meta.url);
const html=await readFile(new URL('index.html',root),'utf8');
const content=JSON.parse(await readFile(new URL('../app/content.json',import.meta.url),'utf8'));
const canonical=await readFile(new URL('../../../docs/developer/desktop-api.md',import.meta.url));
assert.equal(content.sha256,createHash('sha256').update(canonical).digest('hex'));
assert.ok(content.sections.length>20);
for(const section of content.sections)assert.ok(html.includes(`id="${section.id}"`),`Missing section ${section.id}`);
assert.ok(html.includes('<table>'),'API tables must be rendered');
assert.ok(html.includes('复制代码'),'Fenced examples must expose copy controls');
assert.ok(html.includes('/api/v1/remote/'),'Remote API contract must be exported');
const files=[];
async function walk(directory){for(const entry of await readdir(directory,{withFileTypes:true})){const url=new URL(entry.name+(entry.isDirectory()?'/':''),directory);const info=await lstat(url);assert.ok(!info.isSymbolicLink(),'Symlinks are forbidden');if(entry.isDirectory())await walk(url);else{assert.ok(info.size<=8*1024*1024);files.push({url,size:info.size});}}}
await walk(root);assert.ok(files.length<=4096);assert.ok(files.reduce((n,f)=>n+f.size,0)<=64*1024*1024);
for(const match of html.matchAll(/(?:src|href)="(\/_next\/[^"?#]+)[^"]*"/g)){await lstat(new URL('.'+match[1],root));}
for(const file of files.filter(f=>['.html','.css','.js'].includes(path.extname(f.url.pathname)))){
 const source=await readFile(file.url,'utf8');assert.ok(!/https?:\/\/(?:fonts\.googleapis|fonts\.gstatic)\.com/.test(source),'Offline build must not use remote fonts');
}
console.log(`Verified ${content.sections.length} canonical sections and ${files.length} static resources (${files.reduce((n,f)=>n+f.size,0)} bytes).`);

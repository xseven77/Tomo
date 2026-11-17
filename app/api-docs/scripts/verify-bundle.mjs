import assert from 'node:assert/strict';
import {readFile,readdir,lstat} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const expected=new URL('../out/',import.meta.url);
const bundle=process.argv[2];assert.ok(bundle,'Pass the desktop .app bundle path');
const actual=resolve(bundle,'Contents/Resources/ApiDocs');
async function inventory(root,relative=''){
 const result=new Map();
 for(const name of await readdir(root)){
  const file=join(root,name),key=relative+name,info=await lstat(file);
  assert.ok(!info.isSymbolicLink(),`Unexpected symlink ${key}`);
  if(info.isDirectory())for(const [childKey,data] of await inventory(file,key+'/'))result.set(childKey,data);
  else{assert.ok(info.isFile(),`Unexpected resource ${key}`);result.set(key,await readFile(file));}
 }
 return result;
}
const source=await inventory(expected.pathname),packaged=await inventory(actual);
assert.deepEqual([...source.keys()].sort(),[...packaged.keys()].sort(),'Bundle resource inventory differs');
for(const [name,bytes] of source)assert.deepEqual(bytes,packaged.get(name),`Bundled bytes differ: ${name}`);
console.log(`Desktop bundle contains all ${source.size} identical offline documentation resources.`);

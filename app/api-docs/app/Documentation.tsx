'use client';
import {useEffect,useState,isValidElement,type ReactNode} from 'react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
interface Content {title:string;version:string;status:string;sha256:string;source:string;commit:string|null;sections:{id:string;title:string;markdown:string}[]}
function Code({children,className}:{children?:ReactNode;className?:string}){
 const [copied,setCopied]=useState(false);
 const value=String(children??'');
 useEffect(()=>{if(!copied)return;const timer=setTimeout(()=>setCopied(false),1600);return()=>clearTimeout(timer);},[copied]);
 return <div className="code-block"><button type="button" onClick={async()=>{try{await navigator.clipboard.writeText(value);setCopied(true);}catch{setCopied(false);}}}>{copied?'已复制':'复制代码'}</button><pre><code className={className}>{children}</code></pre></div>;
}
export function Documentation({content}:{content:Content}){
 const [query,setQuery]=useState('');const [menu,setMenu]=useState(false);const [mode,setMode]=useState('light');
 useEffect(()=>{const stored=localStorage.getItem('tomo-api-docs-theme');if(stored==='dark')setMode('dark');},[]);
 const words=query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
 const results=content.sections.filter(section=>words.every(word=>section.markdown.toLocaleLowerCase().includes(word)));
 return <div className="docs" data-theme={mode}>
 <header><a className="brand" href="#">Tomo <span>开发文档</span></a><div className="header-actions"><span className="version">next · 未发布</span><button type="button" onClick={()=>{const next=mode==='light'?'dark':'light';setMode(next);localStorage.setItem('tomo-api-docs-theme',next);}} aria-label="切换文档颜色模式">{mode==='light'?'深色':'浅色'}</button><button className="menu-toggle" type="button" aria-expanded={menu} aria-controls="docs-sidebar" onClick={()=>setMenu(!menu)}>目录</button></div></header>
 <aside id="docs-sidebar" data-open={menu}><label className="search-label" htmlFor="search">查找接口与字段</label><input id="search" type="search" placeholder="路径、字段、中文关键词" value={query} onChange={event=>setQuery(event.target.value)}/><p className="search-status" role="status">{query?`${results.length} 个相关章节`:'桌面端开放 API'}</p><nav aria-label="API 文档章节">{results.map(section=><a key={section.id} href={`#${section.id}`} onClick={()=>setMenu(false)}>{section.title}</a>)}</nav>{results.length===0&&<p>未找到匹配章节。</p>}<div className="sidebar-note">文档服务仅提供静态内容。<br/>接口示例使用占位符，不会发起业务请求。</div></aside>
 <main><div className="intro"><span className="eyebrow">DESKTOP / API REFERENCE</span><h1>{content.title}</h1><p>认证、Agent、会话、历史与控制能力的接口参考。</p><div className="metadata"><span>{content.status}</span><span>单一 Markdown 内容源</span><span>离线可查阅</span></div></div>
 {content.sections.map((section,index)=><section className="api-section" key={section.id} id={section.id}><Markdown remarkPlugins={[remarkGfm]} skipHtml components={{h1:({children})=><h2>{children}</h2>,h2:({children})=><h2>{children}</h2>,h3:({children})=><h3>{children}</h3>,pre:({children})=>isValidElement<{children?:ReactNode;className?:string}>(children)?<Code className={children.props.className}>{children.props.children}</Code>:<pre>{children}</pre>,code:({children,className})=><code className={className}>{children}</code>,a:({href,children})=>{const local=href?.startsWith('#');return <a href={href} target={local?undefined:'_blank'} rel={local?undefined:'noreferrer'}>{children}</a>;}}}>{section.markdown}</Markdown>{index===0&&<p className="notice">当前为开发文档，接口实际可用性以对应桌面构建和授权配置为准。</p>}</section>)}
 <footer><p>文档源：{content.source}</p><p>内容 SHA-256：<code>{content.sha256}</code></p><p>源码基线：<code>{content.commit??'未记录'}</code>（包含工作区改动，未冻结发布版本）</p></footer></main>
 </div>;
}

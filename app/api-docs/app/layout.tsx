import type {Metadata} from 'next';
import './globals.css';
export const metadata: Metadata={title:'Tomo 桌面 API 文档',description:'随桌面分发的离线 API 参考文档'};
export default function Layout({children}:{children:React.ReactNode}){return <html lang="zh-CN"><body>{children}</body></html>;}

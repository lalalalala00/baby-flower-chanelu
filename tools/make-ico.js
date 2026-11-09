// media/icon.png → windows/chanelu.ico (PNG 압축 항목 16/32/48/64/128/256)
const fs=require('fs'),cp=require('child_process'),os=require('os'),path=require('path');
const src=process.argv[2]||'media/icon.png',out=process.argv[3]||'windows/chanelu.ico';
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'ico-'));const sizes=[16,32,48,64,128,256];
const pngs=sizes.map(s=>{const f=path.join(tmp,s+'.png');cp.execFileSync('sips',['-z',String(s),String(s),src,'--out',f],{stdio:'ignore'});return fs.readFileSync(f)});
const head=Buffer.alloc(6);head.writeUInt16LE(0,0);head.writeUInt16LE(1,2);head.writeUInt16LE(sizes.length,4);
let off=6+16*sizes.length;const dir=[];
sizes.forEach((s,i)=>{const e=Buffer.alloc(16);e[0]=s>=256?0:s;e[1]=s>=256?0:s;e[2]=0;e[3]=0;e.writeUInt16LE(1,4);e.writeUInt16LE(32,6);e.writeUInt32LE(pngs[i].length,8);e.writeUInt32LE(off,12);off+=pngs[i].length;dir.push(e)});
fs.writeFileSync(out,Buffer.concat([head,...dir,...pngs]));fs.rmSync(tmp,{recursive:true});
console.log(out,fs.statSync(out).size,'bytes');

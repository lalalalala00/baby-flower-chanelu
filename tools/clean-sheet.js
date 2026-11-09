const {PNG}=require('pngjs');const fs=require('fs');
const src=PNG.sync.read(fs.readFileSync(process.argv[2]));const out=process.argv[3];
const W=src.width,D=src.data;
const cols=[[10,106],[138,237],[267,369],[395,498],[526,630],[654,761],[781,890],[912,1019]];
const rows=[[28,139],[175,287],[321,436],[469,587],[612,739],[772,867],[907,994],[1019,1139],[1167,1270],[1296,1400],[1425,1524]];
const PAD=10;const cells=[];
for(let r=0;r<11;r++)for(let c=0;c<8;c++){
  const x0=Math.max(0,cols[c][0]-PAD),x1=Math.min(W-1,cols[c][1]+PAD),y0=Math.max(0,rows[r][0]-PAD),y1=Math.min(src.height-1,rows[r][1]+PAD);
  const w=x1-x0+1,h=y1-y0+1;const a=(x,y)=>D[((y0+y)*W+x0+x)*4+3];
  // largest 8-connected component of alpha>100
  const lab=new Int32Array(w*h).fill(-1);let best=-1,bestN=0,id=0;
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){if(lab[y*w+x]>=0||a(x,y)<=100)continue;
    let st=[y*w+x],n=0;lab[y*w+x]=id;while(st.length){const p=st.pop();n++;const px=p%w,py=(p/w)|0;
      for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){const nx=px+dx,ny=py+dy;if(nx<0||ny<0||nx>=w||ny>=h)continue;const q=ny*w+nx;if(lab[q]<0&&a(nx,ny)>100){lab[q]=id;st.push(q);}}}
    if(n>bestN){bestN=n;best=id;}id++;}
  // mask = best comp dilated by 2 (keeps soft edge), fill holes not needed
  const m=new Uint8Array(w*h);for(let i=0;i<w*h;i++)if(lab[i]===best)m[i]=1;
  const md=new Uint8Array(w*h);for(let y=0;y<h;y++)for(let x=0;x<w;x++){if(!m[y*w+x])continue;for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++){const nx=x+dx,ny=y+dy;if(nx>=0&&ny>=0&&nx<w&&ny<h)md[ny*w+nx]=1;}}
  let bx0=w,by0=h,bx1=0,by1=0;const px=Buffer.alloc(w*h*4);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=y*w+x,s=((y0+y)*W+x0+x)*4;if(!md[i]||D[s+3]<40)continue;
    px[i*4]=D[s];px[i*4+1]=D[s+1];px[i*4+2]=D[s+2];px[i*4+3]=D[s+3];bx0=Math.min(bx0,x);bx1=Math.max(bx1,x);by0=Math.min(by0,y);by1=Math.max(by1,y);}
  cells.push({r,c,w,h,px,bx0,by0,bx1,by1,absBottom:y0+by1});
}
// frame size
let FW=0,FH=0;for(const k of cells){FW=Math.max(FW,k.bx1-k.bx0+1);FH=Math.max(FH,k.by1-k.by0+1);}
const rowBottom=[];for(let r=0;r<11;r++)rowBottom[r]=Math.max(...cells.filter(k=>k.r===r).map(k=>k.absBottom));
let lift=0;for(const k of cells)lift=Math.max(lift,rowBottom[k.r]-k.absBottom);
FW+=8;FH+=8+lift;console.log('frame',FW,FH,'lift',lift);
const sheet=new PNG({width:FW*8,height:FH*11});sheet.data.fill(0);
for(const k of cells){const bw=k.bx1-k.bx0+1,bh=k.by1-k.by0+1;const up=rowBottom[k.r]-k.absBottom;
  const ox=k.c*FW+Math.round((FW-bw)/2),oy=k.r*FH+(FH-4-bh-up);
  for(let y=0;y<bh;y++)for(let x=0;x<bw;x++){const s=((k.by0+y)*k.w+k.bx0+x)*4,t=((oy+y)*sheet.width+ox+x)*4;for(let j=0;j<4;j++)sheet.data[t+j]=k.px[s+j];}}
fs.writeFileSync(out,PNG.sync.write(sheet));
fs.writeFileSync(out.replace('.png','.json'),JSON.stringify({frameWidth:FW,frameHeight:FH,cols:8,rows:11}));
// preview on dark bg
const pv=new PNG({width:sheet.width,height:sheet.height});for(let i=0;i<sheet.width*sheet.height;i++){const a=sheet.data[i*4+3]/255;for(let j=0;j<3;j++)pv.data[i*4+j]=Math.round(sheet.data[i*4+j]*a+30*(1-a));pv.data[i*4+3]=255;}
fs.writeFileSync(out.replace('.png','-preview.png'),PNG.sync.write(pv));

// Render only source-embedded, size-checked Excalidraw raster images.
// No remote URLs, SVG, filesystem files, JavaScript or Chat binary disclosure.
const valid=(w,h)=>Number.isInteger(w)&&Number.isInteger(h)&&w>0&&h>0&&
  w<=8192&&h<=8192&&w*h<=12000000;
const byte=(s,i)=>s.charCodeAt(i);
const u32=(s,i)=>(byte(s,i)*16777216+(byte(s,i+1)<<16)+
  (byte(s,i+2)<<8)+byte(s,i+3))>>>0;
function png(s) {
  if(s.length<33||!s.startsWith("\x89PNG\r\n\x1a\n")||u32(s,8)!==13||
    s.slice(12,16)!=="IHDR")return null;
  const width=u32(s,16),height=u32(s,20);
  return valid(width,height)?{width,height}:null;
}
function jpeg(s) {
  if(s.length<16||byte(s,0)!==255||byte(s,1)!==216)return null;
  let i=2;
  for(let k=0;k<256&&i+3<s.length;k++){
    if(byte(s,i)!==255)return null;
    while(byte(s,i)===255)i++;
    const marker=byte(s,i++);
    if(marker===216||marker===1||(marker>=208&&marker<=215))continue;
    if(marker===217||marker===218||i+1>=s.length)return null;
    const n=byte(s,i)*256+byte(s,i+1);
    if(n<2||i+n>s.length)return null;
    if([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)){
      if(n<7)return null;
      const height=byte(s,i+3)*256+byte(s,i+4);
      const width=byte(s,i+5)*256+byte(s,i+6);
      return valid(width,height)?{width,height}:null;
    }
    i+=n;
  }
  return null;
}
export function inlineExcalidrawBitmap(element,files) {
  if(!element||element.type!=="image"||typeof element.fileId!=="string"||
    !element.fileId||element.fileId.length>256||!files||
    typeof files!=="object"||Array.isArray(files)||
    !Object.hasOwn(files,element.fileId))return null;
  const file=files[element.fileId];
  if(!file||typeof file.dataURL!=="string"||file.dataURL.length>650000)return null;
  const url=file.dataURL;
  const prefix=url.startsWith("data:image/png;base64,")?"data:image/png;base64,":
    url.startsWith("data:image/jpeg;base64,")?"data:image/jpeg;base64,":null;
  if(!prefix||(file.mimeType&&file.mimeType!==prefix.slice(5,-8)))return null;
  const encoded=url.slice(prefix.length);
  if(!encoded||encoded.length%4||!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))return null;
  try{
    const bytes=atob(encoded); // <488 KiB, never network access.
    const dimensions=prefix.includes("png")?png(bytes):jpeg(bytes);
    return dimensions?{href:url,...dimensions}:null;
  }catch{return null;}
}

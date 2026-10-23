import sharp from 'sharp';
export const presets = {
  hero: {width: 1920, height: 800, fit: 'cover', quality: 82},
  category: {width: 900, height: 1100, fit: 'cover', quality: 82},
  product: {width: 1000, height: 1200, fit: 'contain', quality: 85},
  ceo: {width: 600, height: 600, fit: 'cover', quality: 85},
  logo: {width: 400, height: 200, fit: 'contain', quality: 90},
  certification: {width: 400, height: 240, fit: 'contain', quality: 90},
};
export async function compressImage(buffer, kind) {
  const preset = presets[kind];
  if (!preset) throw Object.assign(new Error('Unknown image preset'), {status: 400});
  try {
    const input = sharp(buffer, {limitInputPixels: 40000000, animated: false});
    const metadata = await input.metadata();
    if (!['jpeg','png','webp','avif'].includes(metadata.format)) throw new Error('Unsupported format');
    const {data, info} = await input.rotate().resize({...preset, background: {r:255,g:255,b:255,alpha:0}}).webp({quality: preset.quality, effort: 4}).toBuffer({resolveWithObject: true});
    return {buffer: data, width: info.width, height: info.height, bytes: info.size, contentType: 'image/webp'};
  } catch {
    throw Object.assign(new Error('Upload a valid JPEG, PNG, WebP or AVIF image under 40 megapixels.'), {status: 400});
  }
}

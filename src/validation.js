import { z } from 'zod';
const text = (max = 200) => z.string().trim().max(max);
const required = (max = 200) => text(max).min(1);
export const assetUrl = z.string().max(2000).refine(value => !value || /^\/(?:images|media)\/[a-zA-Z0-9_./-]+$/.test(value) || (() => { try { return new URL(value).protocol === 'https:'; } catch { return false; } })(), 'Use an HTTPS image URL or a local /images/ path');
const order = z.number().int().min(0).max(100000).default(0);
const attributes = z.record(z.string().max(60), z.union([text(200), z.array(text(200)).max(30)])).refine(value => Object.keys(value).length <= 20 && !Object.keys(value).some(key => key.toLowerCase() === 'color' && Array.isArray(value[key])), 'Products have one color only').default({});
export const schemas = {
  hero_banners: z.object({sort_order: order, page: z.enum(['home','about','compliance','mens','womens','girls']), image_url: assetUrl, title: text(200).default(''), accent: text(200).default(''), eyebrow: text(150).default(''), description: text(1000).default(''), is_active: z.boolean().default(true)}).strict(),
  partners: z.object({name: required(100), image_url: assetUrl, website_url: z.union([z.literal(''), z.url().refine(value => new URL(value).protocol === 'https:', 'Use HTTPS')]).default(''), sort_order: order, is_active: z.boolean().default(true)}).strict(),
  categories: z.object({name: required(100), slug: z.string().regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/).max(100), parent_id: z.uuid().nullable(), hero_image_url: assetUrl.default(''), tagline: text(200).default(''), description: text(1000).default(''), config: z.object({filters: z.record(z.string().max(60), z.array(text(100)).max(40)).optional(), benefits: z.array(text(100)).max(4).optional(), banner: text(200).optional(), bannerCopy: text(1000).optional(), bannerImage: assetUrl.optional()}).strict().default({}), sort_order: order, is_active: z.boolean().default(true)}).strict().refine(value => value.parent_id !== null || !['admin','api','media','images','about','products','contact','compliance'].includes(value.slug), 'This URL name is reserved. Choose another category URL.'),
  products: z.object({sku: text(80).optional(), name: required(150), category_id: z.uuid(), description: text(3000).default(''), subtitle: text(200).default(''), image_url: assetUrl.default(''), color_name: text(60).default(''), color_hex: z.string().regex(/^#[0-9a-fA-F]{6}$/).default('#bab4a7'), attributes, pattern: z.enum(['plain','stripes','print','check']).default('plain'), sort_order: order, is_active: z.boolean().default(true)}).strict(),
};
export const quoteSchema = z.object({name: required(100), email: z.email().max(200), company: text(150).default(''), quantity: z.number().int().min(1).max(10000000).nullable().default(null), message: text(2500).default(''), product_id: z.uuid().nullable().default(null), product_sku: text(80).default(''), product_name: required(150), color: text(60).default(''), website: text(200).default('')}).strict();
export const quoteUpdateSchema = z.object({status: z.enum(['new','reviewing','responded','closed']), admin_notes: text(5000).default('')}).strict();
export const idSchema = z.uuid();
export const homeSlidesSchema = z.object({slides: z.array(z.object({
  id: z.uuid().optional(), image_url: assetUrl.refine(value => Boolean(value), 'Select an image'),
  is_active: z.boolean().default(true),
}).strict()).max(30).refine(slides => {
  const ids = slides.filter(slide => slide.id).map(slide => slide.id);
  return new Set(ids).size === ids.length;
}, 'Each slide must appear only once')}).strict();

export const loginSchema = z.object({email: z.email().max(200).transform(value => value.toLowerCase()), password: z.string().min(1).max(1024)}).strict();

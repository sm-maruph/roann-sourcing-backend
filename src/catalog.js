export function adaptCatalog(allCategories, products, audience, hero) {
  const root = allCategories.find(row => row.parent_id === null && row.slug === audience && row.is_active);
  if (!root) return {categories: [], products: []};
  const categories = allCategories.filter(row => row.parent_id === root.id && row.is_active);
  const byId = new Map(allCategories.map(row => [row.id, row]));
  const visibleProducts = products.flatMap(row => {
    const assigned = byId.get(row.category_id);
    if (!assigned?.is_active) return [];
    const category = assigned.level === 3 ? byId.get(assigned.parent_id) : assigned;
    if (!categories.some(item => item.id === category?.id)) return [];
    return [{id: row.sku, databaseId: row.id, name: row.name, category: category.slug, type: assigned.level === 3 ? assigned.name : row.attributes.Style || row.attributes['Product Type'] || category.name, subtitle: row.subtitle, description: row.description, image: row.image_url || undefined, color: row.color_hex, colorName: row.color_name, selectedColor: row.color_name, attributes: {...row.attributes, ...(assigned.level === 3 ? {Subcategory: assigned.name} : {}), ...(row.color_name ? {Color: row.color_name} : {})}, order: row.sort_order, pattern: row.pattern}];
  });
  return {collection: {name: root.name, slug: root.slug}, categories: categories.map(row => {
    const children = allCategories.filter(child => child.parent_id === row.id && child.is_active);
    const filters = {...(row.config.filters || {}), ...(children.length ? {Subcategory: children.map(child => child.name)} : {})};
    for (const product of visibleProducts.filter(item => item.category === row.slug)) {
      for (const [key, value] of Object.entries(product.attributes)) filters[key] = [...new Set([...(filters[key] || []), ...(Array.isArray(value) ? value : [value])])];
    }
    return {id: row.slug, databaseId: row.id, title: row.name, label: row.name, hero: hero?.image_url || row.hero_image_url || '/images/hero.jpg', tagline: row.tagline, description: row.description, tabs: ['All', ...children.map(child => child.name)], subcategories: children.map(child => ({id: child.slug, label: child.name})), filters, benefits: row.config.benefits || ['Premium Sourcing','Quality Manufacturing','Ethical Production','Global Supply Chain'], banner: row.config.banner || 'Custom Designs & Private Label', bannerCopy: row.config.bannerCopy || 'From fabric sourcing to final production, we bring your collection to life.', bannerImage: row.config.bannerImage || row.hero_image_url || '/images/fabric.jpg'};
  }), products: visibleProducts};
}

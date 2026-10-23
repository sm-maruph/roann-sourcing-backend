export function createMediaCleanup(db, storage) {
  let running;
  async function process() {
    const assets = await db.mediaCleanupCandidates();
    for (const asset of assets) {
      try {
        if (await db.mediaIsReferenced(asset.url)) {
          await db.cancelMediaCleanup(asset.id);
          continue;
        }
        // Keep metadata and the queue entry until Storage confirms removal.
        await storage.remove(asset.path);
        await db.completeMediaCleanup(asset.id);
      } catch {
        await db.failMediaCleanup(asset.id).catch(() => {});
        console.error('Image cleanup deferred; it will be retried. Asset:', asset.id);
      }
    }
  }
  return () => {
    if (!running) running = process().finally(() => { running = undefined; });
    return running;
  };
}

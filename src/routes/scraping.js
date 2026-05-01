const { authenticateToken } = require('../middlewares/auth');
const { scrapeProduct } = require('../utils/scraper');

module.exports = function (Router, db) {
  const router = Router();

  // GET /api/scrape/amazon/:asin — scrape Amazon product (auth required)
  router.get('/api/scrape/amazon/:asin', authenticateToken, async (req, res) => {
    const { asin } = req.params;

    try {
      const title = await scrapeProduct('amazon', asin);
      res.json({ title });
    } catch (err) {
      if (err.status === 404) {
        return res.status(404).json({ error: err.message || 'Product not found' });
      }
      res.status(500).json({ error: err.message || 'Failed to scrape product' });
    }
  });

  // GET /api/scrape/etsy/:id — scrape Etsy product (auth required)
  router.get('/api/scrape/etsy/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;

    try {
      const title = await scrapeProduct('etsy', id);
      res.json({ title });
    } catch (err) {
      if (err.status === 404) {
        return res.status(404).json({ error: err.message || 'Product not found' });
      }
      res.status(500).json({ error: err.message || 'Failed to scrape product' });
    }
  });

  // GET /api/scrape/ebay/:id — scrape eBay product (auth required)
  router.get('/api/scrape/ebay/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;

    try {
      const title = await scrapeProduct('ebay', id);
      res.json({ title });
    } catch (err) {
      if (err.status === 404) {
        return res.status(404).json({ error: err.message || 'Product not found' });
      }
      res.status(500).json({ error: err.message || 'Failed to scrape product' });
    }
  });

  return router;
};

const TelegramBot = require('node-telegram-bot-api');
const { Prisma } = require('@prisma/client');

let botInstance = null;

/**
 * Initialize the Telegram Bot integration
 * @param {import('@prisma/client').PrismaClient} db - Prisma client instance
 */
function initTelegramBot(db) {
    const token = process.env.TELEGRAM_BOT_TOKEN;
    const allowedGroupId = process.env.TELEGRAM_GROUP_ID;

    console.log(`[Telegram] Debug: Init attempt at ${new Date().toISOString()} | Token: ${token ? token.substring(0, 10) + '...' : 'MISSING'}`);

    if (!token) {
        console.warn('[Telegram] Missing TELEGRAM_BOT_TOKEN in .env. Bot disabled.');
        return null;
    }

    // Initialize bot with polling after a short delay to avoid 409 conflicts during restarts
    setTimeout(async () => {
        if (botInstance) return;

        try {
            console.log('[Telegram] Preparing bot instance...');
            const bot = new TelegramBot(token);

            // Critical: Delete any existing webhook to ensure polling works
            await bot.deleteWebHook();
            console.log('[Telegram] Webhook cleared.');

            botInstance = new TelegramBot(token, { polling: true });
            console.log('[Telegram] Polling started.');

            botInstance.on('message', async (msg) => {
                try {
                    const chatId = msg.chat.id;
                    const text = msg.text;
                    if (!text) return;

                    console.log(`[Telegram] Message from ${chatId}: ${text.substring(0, 40)}...`);

                    if (text === '/id' || text === '/id@bot_username') {
                        botInstance.sendMessage(chatId, `Chat ID: ${chatId}`);
                        return;
                    }

                    // Header detection for USA holiday report
                    if (text.toUpperCase().includes('BÁO CÁO NGÀY LỆ US')) {
                        const lines = text.split('\n');
                        let currentGroup = 'General';
                        let addedCount = 0;

                        // Clear old holidays before updating
                        await db.usaHoliday.deleteMany();

                        for (const line of lines) {
                            const trimmed = line.trim();
                            if (!trimmed) continue;

                            // Detect Priority Group
                            if (trimmed.includes('[') && trimmed.includes('NGÀY')) {
                                currentGroup = trimmed.replace(/[⚠️🌟]/g, '').trim();
                                continue;
                            }

                            // Detect Holiday Line
                            if (trimmed.includes('➡️')) {
                                const match = trimmed.match(/➡️\s*(.+)\s*\((\d{4}-\d{2}-\d{2})\)\s*-\s*Còn\s*(\d+)\s*ngày/);
                                if (match) {
                                    const [, name, date, daysLeft] = match;
                                    await db.usaHoliday.create({
                                        data: {
                                            name: name.trim(),
                                            date,
                                            days_left: parseInt(daysLeft),
                                            priority_group: currentGroup,
                                            updatedAt: new Date().toISOString(),
                                        },
                                    });
                                    addedCount++;
                                }
                            }
                        }

                        if (addedCount > 0) {
                            botInstance.sendMessage(chatId, `Đã cập nhật ${addedCount} ngày lễ US mới vào lịch countdown!`);
                            console.log(`[Telegram] Updated ${addedCount} holidays.`);
                        }
                    }

                    // Keyword detection
                    if (text.toUpperCase().includes('TỪ KHÓA TÌM KIẾM')) {
                        const lines = text.split('\n');

                        const keywords = lines
                            .map(l => l.trim())
                            .filter(l => l && !l.includes('🔑') && !l.toUpperCase().includes('TỪ KHÓA'));

                        if (keywords.length > 0) {
                            console.log(`[Telegram] Processing ${keywords.length} keywords.`);

                            let addedCount = 0;
                            for (const kw of keywords) {
                                try {
                                    await db.trendingKeyword.create({
                                        data: {
                                            keyword: kw,
                                            heat_score: 85,
                                            category: 'general',
                                            source: 'telegram',
                                        },
                                    });
                                    addedCount++;
                                } catch (err) {
                                    if (err.code !== 'P2002') {
                                        console.error('[Telegram] Keyword insert error:', err.message);
                                    }
                                    // P2002 = unique constraint, skip duplicate
                                }
                            }

                            botInstance.sendMessage(chatId, `Đã cập nhật ${addedCount} keywords mới! (Bỏ qua ${keywords.length - addedCount} trùng lặp)`);
                            console.log(`[Telegram] Added ${addedCount} new keywords.`);
                        }
                    }
                } catch (error) {
                    console.error('[Telegram] Message handling error:', error.message);
                }
            });

            botInstance.on('polling_error', (error) => {
                if (error.code === 'ETELEGRAM' && error.message.includes('409 Conflict')) {
                    console.error('[Telegram] Conflict 409: Một bot khác đang chạy. Đang dừng polling...');
                    botInstance.stopPolling();
                    botInstance = null;
                } else if (error.code !== 'EFATAL') {
                    console.warn(`[Telegram] Polling warning: ${error.message}`);
                }
            });

        } catch (err) {
            console.error('[Telegram] Failed to init bot:', err.message);
        }
    }, 3000);

    // Handle graceful shutdown
    const shutdown = () => {
        if (botInstance) {
            console.log('[Telegram] Stopping bot polling...');
            botInstance.stopPolling();
        }
    };
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);

    return null;
}

/**
 * Send a message to the configured group
 * @param {string} text
 */
function sendMessageToGroup(text) {
    const token = process.env.TELEGRAM_BOT_TOKEN;
    const chatId = process.env.TELEGRAM_GROUP_ID;
    if (!token || !chatId) return;

    const bot = botInstance || new TelegramBot(token);
    bot.sendMessage(chatId, text).catch(err => console.error('[Telegram] Push Message Failed:', err.message));
}

module.exports = { initTelegramBot, sendMessageToGroup };

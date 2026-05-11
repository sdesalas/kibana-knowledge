const puppeteer = require('puppeteer'); // v23.0.0 or later
const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms));
const SECOND = 1000;

(async () => {
    const browser = await puppeteer.launch({
        browser: 'firefox',
        headless: false,
        // userDataDir: '~/Library/Application Support/Google/Chrome'
    });
    const page = await browser.newPage();
    const timeout = 5000;
    page.setDefaultTimeout(timeout);
    await delay(3 * SECOND);

    {
        const targetPage = page;
        await targetPage.setViewport({
            width: 1600,
            height: 577
        })
    }
    {
        const targetPage = page;
        await targetPage.goto('http://localhost:5606/kbn/login');
    }
    await delay(3 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-aria(Username)'),
            targetPage.locator('#\\:r1\\:'),
            targetPage.locator('::-p-xpath(//*[@id=\\":r1:\\"])'),
            targetPage.locator(':scope >>> #\\:r1\\:')
        ])
            .setTimeout(timeout)
            .fill('elastic');
    }
    await delay(1 * SECOND);
    {
        const targetPage = page;
        await targetPage.keyboard.down('Tab');
    }
    {
        const targetPage = page;
        await targetPage.keyboard.up('Tab');
    }
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-aria(Password)'),
            targetPage.locator('#\\:r2\\:'),
            targetPage.locator('::-p-xpath(//*[@id=\\":r2:\\"])'),
            targetPage.locator(':scope >>> #\\:r2\\:')
        ])
            .setTimeout(timeout)
            .fill('changeme');
    }
    await delay(1 * SECOND);
    {
        const targetPage = page;
        await targetPage.keyboard.down('Enter');
    }
    {
        const targetPage = page;
        const promises = [];
        const startWaitingForEvents = () => {
            promises.push(targetPage.waitForNavigation());
        }
        await targetPage.keyboard.up('Enter');
        await Promise.all(promises);
    }
    await delay(3 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Explore on my)')
        ])
            .setTimeout(timeout)
            .click({
              offset: {
                x: 30,
                y: 3,
              },
            });
    }
    await delay(5 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Security)')
        ])
            .setTimeout(timeout)
            .click({
              offset: {
                x: 5,
                y: 3,
              },
            });
    }
    await delay(4 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Rules)')
        ])
            .setTimeout(timeout)
            .click({
              offset: {
                x: 20,
                y: 10,
              },
            });
    }
    await delay(3 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Detection rules)')
        ])
            .setTimeout(timeout)
            .click({
              offset: {
                x: 10,
                y: 12,
              },
            });
    }
    await delay(20 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Add Elastic rules)')
        ])
            .setTimeout(timeout)
            .click({
              offset: {
                x: 10,
                y: 8,
              },
            });
    }
    await delay(12 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Install all)')
        ])
            .setTimeout(timeout)
            .click({
              offset: {
                x: 15,
                y: 10,
              },
            });
    }
    await delay(100 * SECOND);
    {
        const targetPage = page;
        await puppeteer.Locator.race([
            targetPage.locator('::-p-text(Go back to installed)')
        ])
            .setTimeout(60 * SECOND)
            .click({
              offset: {
                x: 144.6171875,
                y: 7.08203125,
              },
            });
    }
    await delay(20 * SECOND);

    await browser.close();

})().catch(err => {
    console.error(err);
    process.exit(1);
});

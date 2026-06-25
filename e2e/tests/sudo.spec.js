const {runSuite, runTest, loginAsAdmin, navigateToAdmin, confirmModal, BASE_URL, LDAP_TIMEOUT, LDAP_ACTION_TIMEOUT} = require('./helpers');

const TEST_RULE = 'e2e-test-sudo-rule';

// DataTable renders data-e2e as "${prefix}-search" on the search input
const TABLE_SELECTOR = '[data-e2e="sudo-rules-table-search"]';

async function run(reporter) {
    await runSuite('sudo', async (browser, reporter) => {
        const page = await browser.newPage();
        await loginAsAdmin(page);

        await runTest(page, reporter, 'sudo', 'list-rules', async () => {
            await navigateToAdmin(page, 'sudo-rules');
            await page.waitForSelector(TABLE_SELECTOR, {timeout: LDAP_TIMEOUT});
        });

        await runTest(page, reporter, 'sudo', 'create-rule', async () => {
            await page.click('[data-e2e="sudo-rules-btn-new"]');
            await page.waitForSelector('[data-e2e="sudo-rules-input-name"]', {timeout: 10000});
            await page.fill('[data-e2e="sudo-rules-input-name"]', TEST_RULE);
            await page.fill('[data-e2e="sudo-rules-input-users"]', 'Administrator');
            await page.fill('[data-e2e="sudo-rules-input-hosts"]', 'ALL');
            await page.fill('[data-e2e="sudo-rules-input-commands"]', '/usr/bin/systemctl status nginx');
            await page.fill('[data-e2e="sudo-rules-input-options"]', 'NOPASSWD');
            await page.fill('[data-e2e="sudo-rules-input-description"]', 'Created by E2E tests');
            await page.click('[data-e2e="sudo-rules-btn-submit"]');
            await page.waitForSelector('[data-e2e="sudo-rules-input-name"]', {state: 'hidden', timeout: LDAP_ACTION_TIMEOUT});
            await page.waitForSelector(TABLE_SELECTOR, {timeout: LDAP_TIMEOUT});
        });

        await runTest(page, reporter, 'sudo', 'verify-created', async () => {
            await page.waitForSelector(`text=${TEST_RULE}`, {timeout: LDAP_TIMEOUT});
        });

        await runTest(page, reporter, 'sudo', 'edit-rule', async () => {
            const rows = await page.$$('tr');
            let edited = false;
            for (const row of rows) {
                const text = await row.evaluate(el => el.textContent);
                if (text.includes(TEST_RULE)) {
                    const editLink = await row.$('[data-e2e="sudo-rules-link-edit"]');
                    if (editLink) {
                        await editLink.click();
                        edited = true;
                    }
                    break;
                }
            }
            if (!edited) throw new Error(`Could not find edit link for ${TEST_RULE}`);

            await page.waitForSelector('[data-e2e="sudo-rules-input-name"]', {timeout: 10000});
            await page.fill('[data-e2e="sudo-rules-input-description"]', 'Updated by E2E tests');
            await page.click('[data-e2e="sudo-rules-btn-submit"]');
            await page.waitForSelector('[data-e2e="sudo-rules-input-name"]', {state: 'hidden', timeout: LDAP_ACTION_TIMEOUT});
        });

        await runTest(page, reporter, 'sudo', 'delete-rule', async () => {
            await page.waitForSelector(TABLE_SELECTOR, {timeout: LDAP_TIMEOUT});
            await page.waitForSelector(`text=${TEST_RULE}`, {timeout: LDAP_TIMEOUT});
            const rows = await page.$$('tr');
            for (const row of rows) {
                const text = await row.evaluate(el => el.textContent);
                if (text.includes(TEST_RULE)) {
                    const deleteBtn = await row.$('[data-e2e="sudo-rules-btn-delete"]');
                    if (deleteBtn) {
                        await deleteBtn.click();
                        break;
                    }
                }
            }
            await confirmModal(page, 'sudo-rules-delete');
            await page.waitForTimeout(3000);
        });

        await runTest(page, reporter, 'sudo', 'verify-deleted', async () => {
            await page.goto(`${BASE_URL}/admin/sudo`);
            await page.waitForSelector(TABLE_SELECTOR, {timeout: LDAP_TIMEOUT});
            const stillThere = await page.$(`text=${TEST_RULE}`);
            if (stillThere) throw new Error(`Rule ${TEST_RULE} still present after delete`);
        });

        await page.close();
    }, reporter);
}

module.exports = {run};

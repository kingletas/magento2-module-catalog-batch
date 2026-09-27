# Changelog

All notable changes to this module are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.1.0 - 2026-09-26

Tooling only. The store proof adds three configurable products of its own to a store that has fewer, indexes their stock so the storefront lists them, and removes them afterwards, rather than refusing to run. Nothing about how the module behaves changed.

Requires PHP 8.4 or later, like the rest of the public modules. PHP 8.3 is two releases behind the current 8.5.

### Fixed

- The install section added `repo.magento.com` beside the package feed, which stops `composer require` with a 401 on a Mage-OS store that has no keys for it. It now adds only the feed, beside the repository the store already uses, with one `composer config` command instead of a hand-edited block.

## 1.0.0 - 2026-09-23

### Added

- First release. A category page asks for every configurable product's super attributes, store labels and option rows once instead of once per product, by filling in the collection Magento checks for before it queries.
- Two observers and a before plugin, in the frontend area only. The observers note the configurables each collection loads, and the plugin answers a whole group the first time Magento asks about one of them.
- Attribute collections are built when the page first asks about a configurable, not when a collection loads, so a product page doesn't pay for its related products block: it costs 109 statements, the same as Magento.
- A per store view switch, off on install, and a batch size so one query can't grow without a bound.
- Works beside `kingletas/module-catalog-index`, which answers the same call. The plugin is sorted after that module's (`sortOrder` 20 against 10), so a configurable with a document is answered from it and this module answers the rest. A product the other plugin already answered is let go, so a group it answered in full holds nothing and runs no query.
- `kingletas:catalog-batch:status`, which shows how many products this module answered and how many another module answered first. The counts are kept per hour in the application cache and written once per request only when that request counted something.
- **Batch The Salable Child Count**, a second switch, off on install. A listing's configurables have their buyable children counted for the whole listing the first time Magento asks about one, instead of one query per product, through two constructor arguments of Magento's configurable type model rather than a plugin. Magento's own salable filter still decides which children count.
- Requires PHP 8.3 or later; the suites and the syntax check run on 8.3 and 8.4.

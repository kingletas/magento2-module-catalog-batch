# Kingletas_CatalogBatch

Magento asks the database about a configurable product's attributes **once per product**. On a category page with twelve configurables, that's forty-eight queries for information two queries could have fetched. This module asks once per page.

It stores no catalog data. There's no index, no cron job, no second datastore and nothing to go stale. It reads the same tables Magento reads, at the moment Magento would read them, and hands each product the answer it was about to ask for.

New to it? Start with [From nothing to a working module-catalog-batch](docs/from-nothing.md).

## What it removes

Magento runs three kinds of query once for every configurable product on the page. The module answers the first two together:

| Query | Magento | With this module |
|---|---|---|
| `catalog_product_super_attribute`, which attributes tell the variants apart | one per product | one per page, with the labels |
| `catalog_product_super_attribute_label`, what to call them in this store | one per product | answered by the query above |
| The option rows behind every swatch | one per attribute per product | one per page |

Take a category page of twelve configurables with two super attributes each. Magento asks 48 times: 12 attribute queries, 12 label queries and 24 option queries. This module asks twice.

## How it works

`Magento\ConfigurableProduct\Model\Product\Type\Configurable::getConfigurableAttributes()` returns early when the product already carries a `_cache_instance_configurable_attributes` collection. The module fills that collection in before Magento looks.

It works in two parts:

- **Two observers note what a page loaded.** `catalog_product_collection_load_after` notes the configurables in each loaded collection, and `catalog_controller_product_view` notes the product a product page is showing. Each collection's products are kept together as one group, with the store and website they were loaded for. Nothing is queried yet.
- **A before plugin answers when Magento asks.** The first time Magento calls `getConfigurableAttributes()` for any product in a group, the plugin answers the whole group with two queries: the attribute rows with their labels, then the option rows.

A collection whose products Magento never asks about, like a related products block, costs nothing. If Magento asks with a different object for the same product, it gets the same answer. A product that no collection noted, like one in the shopping cart, goes down Magento's own path.

The collection it builds is a real `Attribute\Collection` with its items already in it and its loaded flag set. Anything that loops over it, counts it or calls `getItems()` on it behaves as it did before.

The plugin is a before plugin, not an around plugin. The observers and the plugin are registered for the storefront (the frontend area) only.

## Buyable children, with their own switch

Magento also asks, once per configurable, whether any of its children can be bought, so it can show a price and an add to cart button. That is one counting query per product. **Batch The Salable Child Count** answers it for the whole listing the first time Magento asks about one of its products: one query for the listing's child links and one for which children Magento's own salable filter keeps, so whichever inventory module is installed still decides. The first page of a category of configurables goes from 73 database statements to 63; a configurable product page is unchanged.

It uses no plugin. The configurable type model counts through two of its constructor arguments, its child collection factory and its salable processor, and this module replaces both in the frontend area only. Magento's filters are still applied to every child collection, so anything that loads the children loads exactly what it would have; only the count is answered from the page. A product the listing did not load, or one asked about for another store, is counted by Magento as before.

The switch is off on install and does not depend on the attribute switch.

## With the catalog index module

`kingletas/module-catalog-index` answers the same Magento call from its OpenSearch documents when its swatch attribute switch is on. Both can be on in one store, and which one answers is fixed rather than left to install order.

**The index module answers first.** Its plugin declares `sortOrder="10"` and this module's declares `20`. A configurable with a document gets its attributes from that document, with no query of this module's. This module then answers every configurable the index had no document for, with its one query for the page.

A product the index module already answered is let go rather than held for later, so a page it answered in full holds nothing here and runs no query. `kingletas:catalog-batch:status` counts those products as answered first by another module.

**What you'll see with both on:** on a store where every configurable has a document, most products show as answered first by another module. That's the intended order, not a fault: the index module already took those queries off the page. Where documents are missing, this module answers those products and its answered count rises.

## Checking it

```bash
bin/magento kingletas:catalog-batch:status
```

```bash
bin/magento kingletas:catalog-batch:status --hours=1
```

It shows two counts over the last 24 hours, or the hours you ask for: products this module answered, and products another module answered before it could. They're kept per hour in the application cache, never in the database, and written once per request only when that request counted something. So with the switch off it writes nothing, and a cache flush clears them.

## Installing it

Nothing here is on Packagist, and Composer only reads a `repositories` list from the package you're installing into. So add the Kingletas package feed to your store's own `composer.json`, beside the repository your store already installs Magento from. From the store's root:

```bash
composer config repositories.kingletas composer https://kingletas.github.io/packages
```

It serves this module. Don't add `repo.magento.com` if your store doesn't already use it: a Mage-OS store has no keys for it, and Composer stops with a 401 before it resolves anything.

Then:

```bash
composer require kingletas/module-catalog-batch
```

```bash
bin/magento module:enable Kingletas_CatalogBatch && bin/magento setup:upgrade
```

In production mode, also run `bin/magento setup:di:compile` and `bin/magento setup:static-content:deploy`.

**The switch is off when you install it.** Turn it on per store view under **Stores › Configuration › Kingletas › Catalog Batch**, or from the command line:

```bash
bin/magento config:set kingletas_catalog_batch/general/enabled 1
```

```bash
bin/magento cache:flush
```

| Setting | Default | What it decides |
|---|---|---|
| `kingletas_catalog_batch/general/enabled` | `0` | Whether a page's configurable queries are batched at all. Set per store view |
| `kingletas_catalog_batch/general/batch_size` | `100` | How many configurables one query may cover. A bigger group is split across several. Set globally only |

## Before you turn it on

- **It won't make a product page faster.** On a configurable product page it breaks even: measured on Adobe Commerce 2.4.8-p2, that page costs 109 statements with the module and 109 without. The savings are on listings. The same store's category page of twelve configurables went from 169 statements to 123.
- **It merges queries, it doesn't remove them.** A page still talks to the database. If you need a browse page that never touches the database, that's a different design and a different module.
- **It doesn't filter options by salability.** Magento's storefront filters option rows to the current website, and this module does the same. Magento Inventory also adds a salability filter when a website uses a stock other than the default one and the store hides out of stock products. This module doesn't reproduce that filter, so **leave it off on such a store** until the gap is closed.
- **The salable count replaces two arguments of Magento's configurable type model for the whole storefront.** Area `di.xml` replaces an argument rather than merging it, so another extension that sets `productCollectionFactory` or `salableProcessor` on that class in the frontend area silently wins or loses to this one, depending on module order. Check for one before turning the switch on.
- **It touches nothing in the admin or the API.** Everything on a request path is registered in the frontend area. The status command is the only thing registered outside it.

## Requirements

PHP 8.4 or later, and Magento Open Source or Adobe Commerce 2.4.8 or later.

## Working on it

```bash
make help
```

```bash
make check
```

`make check` runs the coding standard and every suite. The suites need a Magento vendor tree, so point `M2_VENDOR` at one or run the shared harness from the repository root.

The module has no public PHP API: every class is internal, and what it offers is its configuration paths and the `kingletas:catalog-batch:status` command.

## Licence

OSL-3.0. See [LICENSE](LICENSE).

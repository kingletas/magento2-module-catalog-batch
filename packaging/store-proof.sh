#!/usr/bin/env bash
#
# store-proof.sh — assert, against a real Magento, the things this module claims
# that no unit test can reach.
#
# Run by bin/store-proof, which has already installed the module the way
# somebody else would, enabled it, and run setup:upgrade twice. See
# `bin/store-proof -h` for what this is given.
#
# Every assertion is made in BOTH directions, because this module's failures are
# symmetrical. A module that batches nothing and one that batches correctly look
# identical if you only ever measure the enabled case, and a module that returns
# the wrong attributes measures fastest of all.
#
# The measurement is the whole claim: the same page, asked the same question,
# costs fewer queries with the switch on and gives the same answer.

set -euo pipefail

MODULE_NAME="Kingletas_CatalogBatch"
ENABLED_PATH="kingletas_catalog_batch/general/enabled"
MEASURE="${STORE_PROOF_STORE}/local.d/store-proof-catalog-batch.php"
FLAG="${STORE_PROOF_STORE}/local.d/store-proof-catalog-batch-flag.php"
AREAS="${STORE_PROOF_STORE}/local.d/store-proof-catalog-batch-areas.php"
SEED="${STORE_PROOF_STORE}/local.d/store-proof-catalog-batch-seed.php"
seeded=0
failures=0

step() { printf '    %s\n' "$*"; }
bad() { printf '    FAILED: %s\n' "$*" >&2; failures=$((failures + 1)); }

value() { $STORE_PROOF_SQL 2>&1 <<< "$1" | tail -1 | tr -d '[:space:]'; }
# Reads key=value out of a measurement line without a regex, so no sed dialect
# gets to decide whether a proof passes.
field() {
	local token
	for token in $1; do
		case "$token" in
			"$2"=*) printf '%s' "${token#*=}"; return 0 ;;
		esac
	done
	return 1
}

cleanup() {
	$STORE_PROOF_MAGENTO config:set "$ENABLED_PATH" 0 >/dev/null 2>&1 || true
	if [ "$seeded" = "1" ]; then
		$STORE_PROOF_PHP /app/local.d/store-proof-catalog-batch-seed.php remove >/dev/null 2>&1 || true
	fi
	$STORE_PROOF_MAGENTO cache:flush >/dev/null 2>&1 || true
	rm -f "$MEASURE" "$FLAG" "$AREAS" "$SEED"
}
trap cleanup EXIT

# --- the store has to be able to show the difference -------------------------

# A store with one configurable cannot demonstrate batching: one product is one
# query either way. A store with fewer than three is given three of its own,
# removed again at the end, and still fails by name if they could not be made.
mkdir -p "${STORE_PROOF_STORE}/local.d"
cat > "$SEED" <<-'PHP'
	<?php
	declare(strict_types=1);

	/**
	 * Adds, or with "remove" takes away, three configurable products on a throwaway attribute.
	 */

	require '/app/app/bootstrap.php';

	use Magento\Catalog\Api\ProductRepositoryInterface;
	use Magento\Catalog\Model\Product;
	use Magento\Framework\App\Bootstrap;

	const CODE = 'store_proof_batch';
	const SKU = 'store-proof-batch';

	$objectManager = Bootstrap::create(BP, $_SERVER)->getObjectManager();
	$objectManager->get(\Magento\Framework\App\State::class)->setAreaCode('adminhtml');
	$objectManager->get(\Magento\Framework\Registry::class)->register('isSecureArea', true);
	$repository = $objectManager->get(ProductRepositoryInterface::class);
	$setup = $objectManager->get(\Magento\Eav\Setup\EavSetupFactory::class)->create([
	    'setup' => $objectManager->get(\Magento\Framework\Setup\ModuleDataSetupInterface::class),
	]);

	if (($argv[1] ?? '') === 'remove') {
	    foreach ([1, 2, 3] as $n) {
	        foreach (["-$n", "-$n-0", "-$n-1"] as $suffix) {
	            try {
	                $repository->deleteById(SKU . $suffix);
	            } catch (\Throwable) {
	                // Already gone.
	            }
	        }
	    }
	    $setup->removeAttribute(Product::ENTITY, CODE);
	    echo "removed\n";
	    exit(0);
	}

	$setup->addAttribute(Product::ENTITY, CODE, [
	    'type' => 'int',
	    'input' => 'select',
	    'label' => 'Store proof batch',
	    'global' => \Magento\Eav\Model\Entity\Attribute\ScopedAttributeInterface::SCOPE_GLOBAL,
	    'user_defined' => true,
	    'required' => false,
	    'group' => 'General',
	    'option' => ['values' => ['first', 'second']],
	]);
	$attribute = $objectManager->create(\Magento\Eav\Model\Config::class)->getAttribute(Product::ENTITY, CODE);
	$options = array_values($attribute->getSource()->getAllOptions(false));
	$setId = (int) $objectManager->get(Product::class)->getDefaultAttributeSetId();
	$factory = $objectManager->get(\Magento\ConfigurableProduct\Helper\Product\Options\Factory::class);

	foreach ([1, 2, 3] as $n) {
	    $children = [];
	    $values = [];
	    foreach ($options as $i => $option) {
	        $child = $objectManager->create(Product::class)
	            ->setTypeId('simple')->setAttributeSetId($setId)->setWebsiteIds([1])
	            ->setName("Store proof $n $i")->setSku(SKU . "-$n-$i")->setPrice(10)
	            ->setVisibility(1)->setStatus(1)
	            ->setStockData(['use_config_manage_stock' => 1, 'qty' => 100, 'is_in_stock' => 1]);
	        $child->setData(CODE, $option['value']);
	        $children[] = (int) $repository->save($child)->getId();
	        $values[] = ['label' => $option['label'], 'attribute_id' => $attribute->getId(), 'value_index' => $option['value']];
	    }
	    $parent = $objectManager->create(Product::class)
	        ->setTypeId('configurable')->setAttributeSetId($setId)->setWebsiteIds([1])
	        ->setName("Store proof configurable $n")->setSku(SKU . "-$n")
	        ->setVisibility(4)->setStatus(1)
	        ->setStockData(['use_config_manage_stock' => 1, 'is_in_stock' => 1]);
	    $extension = $parent->getExtensionAttributes();
	    $extension->setConfigurableProductOptions($factory->create([[
	        'attribute_id' => $attribute->getId(),
	        'code' => CODE,
	        'label' => 'Store proof batch',
	        'position' => 0,
	        'values' => $values,
	    ]]));
	    $extension->setConfigurableProductLinks($children);
	    $parent->setExtensionAttributes($extension);
	    $repository->save($parent);
	}

	echo "seeded=3\n";
PHP

configurables="$(value "SELECT COUNT(*) FROM catalog_product_entity WHERE type_id = 'configurable';")"
if [ "${configurables:-0}" -lt 3 ]; then
	step "the store has ${configurables:-0} configurable products, so the proof adds three of its own"
	seeded=1
	seed_out="$($STORE_PROOF_PHP /app/local.d/store-proof-catalog-batch-seed.php 2>&1 | tail -3)"
	grep -q '^seeded=3$' <<< "$seed_out" || { echo "    could not add configurable products: ${seed_out}" >&2; exit 1; }
	# The storefront shows only what the stock index lists, and saving a product
	# does not index a configurable's stock, so the proof does what cron would.
	$STORE_PROOF_MAGENTO indexer:reindex cataloginventory_stock >/dev/null
	if $STORE_PROOF_MAGENTO indexer:info | grep -q '^inventory '; then
		$STORE_PROOF_MAGENTO indexer:reindex inventory >/dev/null
	fi
	configurables="$(value "SELECT COUNT(*) FROM catalog_product_entity WHERE type_id = 'configurable';")"
fi
if [ "${configurables:-0}" -lt 3 ]; then
	echo "    this proof needs at least 3 configurable products and this store has ${configurables:-0}" >&2
	exit 1
fi
step "the store has ${configurables} configurable products to batch"

# --- what installing it did, and did not do ----------------------------------

step "the module reports itself enabled"
if ! $STORE_PROOF_MAGENTO module:status "$MODULE_NAME" 2>&1 | grep -qi 'enabled'; then
	bad "Magento does not report ${MODULE_NAME} as enabled"
fi

# A performance module that starts changing pages on install is how somebody
# else's store breaks on upgrade day. The README says the switch is off.
#
# Asked of Magento rather than of config:show, which prints nothing at all for a
# path whose only value is an XML default, so an unset path and a wrong one look
# identical to a shell reading its output.
cat > "$FLAG" <<-'PHP'
	<?php
	declare(strict_types=1);

	/**
	 * Reports the effective switch on the default store view.
	 */

	require '/app/app/bootstrap.php';

	use Magento\Framework\App\Bootstrap;
	use Magento\Store\Model\ScopeInterface;

	$objectManager = Bootstrap::create(BP, $_SERVER)->getObjectManager();
	$flag = $objectManager->get(\Magento\Framework\App\Config\ScopeConfigInterface::class)
	    ->isSetFlag('kingletas_catalog_batch/general/enabled', ScopeInterface::SCOPE_STORE, 1);

	printf("enabled=%d\n", $flag ? 1 : 0);
PHP

step "the switch is off on a fresh install"
installed_flag="$($STORE_PROOF_PHP /app/local.d/store-proof-catalog-batch-flag.php | tail -1)"
[ "$(field "$installed_flag" enabled)" = "0" ] \
	|| bad "the switch is already on after a fresh install, so installing the module changes pages"

step "no index and nothing stored"
tables="$(value "SELECT COUNT(*) FROM information_schema.TABLES
	WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'kingletas_catalog_batch%';")"
[ "$tables" = "0" ] || bad "expected no tables, found ${tables}, and the module claims it stores nothing"

# --- the measurement ---------------------------------------------------------

cat > "$MEASURE" <<-'PHP'
	<?php
	declare(strict_types=1);

	/**
	 * Loads configurables the way a category page does and reports what it cost.
	 */

	require '/app/app/bootstrap.php';

	use Magento\Framework\App\Area;
	use Magento\Framework\App\Bootstrap;
	use Magento\Framework\App\State;
	use Magento\Framework\ObjectManager\ConfigLoaderInterface;

	$objectManager = Bootstrap::create(BP, $_SERVER)->getObjectManager();
	$objectManager->get(State::class)->setAreaCode(Area::AREA_FRONTEND);

	// The observers and the plugin are declared in etc/frontend only, so the
	// storefront's own object manager configuration has to be the one loaded.
	$objectManager->configure(
	    $objectManager->get(ConfigLoaderInterface::class)->load(Area::AREA_FRONTEND)
	);

	$collection = $objectManager->create(
	    \Magento\Catalog\Model\ResourceModel\Product\CollectionFactory::class
	)->create();
	$collection->addAttributeToSelect(['name', 'sku'])
	    ->addAttributeToFilter('type_id', 'configurable')
	    ->setPageSize(20);

	// Counted on the collection's own connection, so the session counter and the
	// queries being counted are the same session even where a store has a
	// separate read connection configured.
	$connection = $collection->getConnection();
	$counter = static function () use ($connection): int {
	    $row = $connection->fetchRow("SHOW SESSION STATUS LIKE 'Com_select'");

	    return (int) ($row['Value'] ?? 0);
	};

	// Loading sits outside the measurement: every run pays for it, and what this
	// module changes is what the page costs when it asks about each product.
	$collection->load();

	$configurable = $objectManager->get(
	    \Magento\ConfigurableProduct\Model\Product\Type\Configurable::class
	);

	$before = $counter();
	$seen = [];
	$collectionClass = 'none';
	$realCollection = 0;

	foreach ($collection as $product) {
	    $attributes = $configurable->getConfigurableAttributes($product);

	    if ($collectionClass === 'none') {
	        $collectionClass = get_class($attributes);
	        // Magento serves an Interceptor subclass, so the name is not the
	        // test. What matters is that it is still Magento's own collection.
	        $realCollection = $attributes instanceof \Magento\ConfigurableProduct\Model\ResourceModel\Product\Type\Configurable\Attribute\Collection ? 1 : 0;
	    }

	    $row = [];
	    foreach ($attributes as $attribute) {
	        $row[] = (int) $attribute->getAttributeId() . ':' . (string) $attribute->getLabel();
	    }
	    sort($row);
	    $seen[(int) $product->getId()] = $row;
	}

	$after = $counter();
	ksort($seen);

	printf(
	    "selects=%d products=%d collection=%s real=%d fingerprint=%s\n",
	    $after - $before,
	    count($seen),
	    $collectionClass,
	    $realCollection,
	    md5(json_encode($seen, JSON_THROW_ON_ERROR))
	);
PHP

measure() {
	$STORE_PROOF_MAGENTO config:set "$ENABLED_PATH" "$1" >/dev/null
	$STORE_PROOF_MAGENTO cache:flush >/dev/null
	$STORE_PROOF_PHP /app/local.d/store-proof-catalog-batch.php | tail -1
}

step "measuring with the switch off"
off="$(measure 0)"
step "  ${off}"

step "measuring with the switch on"
on="$(measure 1)"
step "  ${on}"

off_selects="$(field "$off" selects)"
on_selects="$(field "$on" selects)"
off_products="$(field "$off" products)"
on_products="$(field "$on" products)"

# A meter that never moves would make the comparison below pass for a module
# that does nothing at all, which is the failure this script exists for.
step "the query meter moved with the switch off"
if [ "${off_selects:-0}" -le 0 ]; then
	bad "no queries were counted with the switch off, so the comparison proves nothing either way"
fi

step "the switch on costs fewer queries"
if [ "${on_selects:-0}" -ge "${off_selects:-0}" ]; then
	bad "${on_selects} queries with the switch on against ${off_selects} with it off, so nothing is being batched"
fi

step "the same products were asked both times"
if [ "$off_products" != "$on_products" ] || [ "${off_products:-0}" -le 0 ]; then
	bad "compared ${off_products} products against ${on_products}, so the two runs are not the same page"
fi

# Cheaper and different is not an optimisation, it is a bug, and a query count
# on its own can never catch it.
step "the answer is identical"
if [ "$(field "$off" fingerprint)" != "$(field "$on" fingerprint)" ]; then
	bad "the attributes differ between the two runs, so batching changes what the page shows"
fi

# Magento loops over this, counts it and calls getItems() on it. An array would
# pass every unit test and take the storefront down.
step "what the module seeds is a real attribute collection"
[ "$(field "$on" real)" = "1" ] \
	|| bad "the seeded value is '$(field "$on" collection)', which is not one of Magento's attribute collections"

# --- the wiring belongs to the storefront alone ------------------------------

cat > "$AREAS" <<-'PHP'
	<?php
	declare(strict_types=1);

	/**
	 * Reports which areas declare this module's observers.
	 */

	require '/app/app/bootstrap.php';

	use Magento\Framework\App\Bootstrap;

	$objectManager = Bootstrap::create(BP, $_SERVER)->getObjectManager();
	$reader = $objectManager->create(\Magento\Framework\Event\Config\Reader::class);

	$count = static function (string $scope) use ($reader): int {
	    $found = 0;
	    foreach ($reader->read($scope) as $observers) {
	        foreach (array_keys($observers) as $name) {
	            if (str_starts_with((string) $name, 'kingletas_catalog_batch_')) {
	                $found++;
	            }
	        }
	    }

	    return $found;
	};

	printf(
	    "frontend=%d adminhtml=%d global=%d\n",
	    $count('frontend'),
	    $count('adminhtml'),
	    $count('global')
	);
PHP

step "checking which areas declare the observers"
areas="$($STORE_PROOF_PHP /app/local.d/store-proof-catalog-batch-areas.php | tail -1)"
step "  ${areas}"

step "the storefront declares all three observers"
[ "$(field "$areas" frontend)" = "3" ] \
	|| bad "the storefront declares $(field "$areas" frontend) of this module's observers, expected 3"

# An observer that also runs in the admin would batch an import or a mass
# action, which is work this module was never measured against.
step "no other area declares any of them"
for scope in adminhtml global; do
	[ "$(field "$areas" "$scope")" = "0" ] \
		|| bad "the ${scope} scope declares $(field "$areas" "$scope") of this module's observers, expected none"
done

# --- verdict -----------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
	printf '\n    %d assertion(s) failed\n' "$failures" >&2
	exit 1
fi

printf '    every assertion held\n'

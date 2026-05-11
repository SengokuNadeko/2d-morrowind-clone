class_name LootTable
extends Resource

@export var entries: Array[LootTableEntry] = []
## Hard cap on total items spawned per roll. 0 = no cap.
@export var max_drops: int = 0

func roll() -> Array[ItemData]:
	var drops: Array[ItemData] = []
	for entry in entries:
		if entry.item == null:
			continue
		if randf() <= entry.drop_chance:
			var qty := randi_range(entry.min_quantity, entry.max_quantity)
			for i in range(qty):
				drops.append(entry.item)
	if max_drops > 0 and drops.size() > max_drops:
		drops.shuffle()
		drops.resize(max_drops)
	return drops

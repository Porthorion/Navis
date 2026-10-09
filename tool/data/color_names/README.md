# Colour-name data

`colornames.bestof.csv` contains 4,961 rows from
[meodai/color-names](https://github.com/meodai/color-names), tag `v14.51.0`,
file `src/colornames.csv`. The upstream file's SHA-256 is:

```text
79d4eac5dea28703ca7ddda35d46f3e0c8dbbb69b64f53d7ee13c8160e6e7fed
```

The filter keeps rows whose `good name` column is exactly `x`, and writes
only the `name,hex` columns. The dataset is MIT-licensed, copyright David
Aerne; see [LICENSE](LICENSE). Its in-app notice is
`assets/licenses/color-names-MIT.txt`.

To reproduce the filtered input, obtain the upstream file at that tag as
`/tmp/colornames.csv`, verify its SHA-256, then run from the repository root:

```bash
sha256sum /tmp/colornames.csv
python3 - <<'PY'
import csv
from pathlib import Path

with Path('/tmp/colornames.csv').open(newline='', encoding='utf-8') as source:
    rows = [row for row in csv.DictReader(source) if row['good name'] == 'x']
with Path('tool/data/color_names/colornames.bestof.csv').open(
    'w', newline='', encoding='utf-8'
) as destination:
    writer = csv.writer(destination, lineterminator='\n')
    writer.writerow(['name', 'hex'])
    writer.writerows((row['name'], row['hex']) for row in rows)
PY
dart run tool/generate_color_names.dart
```

The Dart generator sorts names using `String.compareTo`, then deduplicates
hex values, keeping the first name for each value. It writes and formats
`lib/src/features/settings/domain/color_name_table.g.dart`. Commit both the
filtered input and generated output when updating the pin.

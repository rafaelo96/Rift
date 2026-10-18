import json, sys
from pathlib import Path
import numpy as np
from PIL import Image

folder = Path(sys.argv[1])
metrics = json.loads((folder/'metrics.json').read_text())
records = metrics['records']
span2 = [r for r in records if r['span'] == 2]

print(f"Total span2 triplets evaluated: {len(span2)}")
changed_fractions = [r['changedFraction'] for r in span2]
print(f"Mean changed fraction inside work plane: {np.mean(changed_fractions)*100:.2f}%")
print(f"Max changed fraction: {np.max(changed_fractions)*100:.2f}%")

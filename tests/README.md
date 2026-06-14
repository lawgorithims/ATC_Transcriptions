# Tests

Smoke tests and environment checks.

| Script | Purpose |
|--------|---------|
| `test_audio.py` | Audio input/output and preprocessing checks |
| `check_gpu.py` | CUDA / GPU availability check |

Run from project root:

```bash
python tests/check_gpu.py
python tests/test_audio.py
```

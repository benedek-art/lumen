import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
collect_ignore = ["test_dng.py"]  # needs real sample RAWs + Adobe DNG Converter (Mac only)

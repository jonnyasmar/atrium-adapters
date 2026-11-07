#!/usr/bin/env python3
import sqlite3
import sys
from pathlib import Path

sql_path, output_path = map(Path, sys.argv[1:])
with sqlite3.connect(output_path) as connection:
    connection.executescript(sql_path.read_text())

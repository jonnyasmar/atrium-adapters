import sqlite3
import sys
from pathlib import Path

connection = sqlite3.connect(sys.argv[1])
try:
    connection.executescript(Path(__file__).with_name('fixture.sql').read_text())
finally:
    connection.close()

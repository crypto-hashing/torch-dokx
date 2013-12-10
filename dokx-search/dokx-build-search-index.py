"""
Create and populate a minimal PostgreSQL schema for full text search
"""

import sqlite3
import glob
import os
import re
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=str, help="Path to write SQLite3 search index")
parser.add_argument("--debug", type=bool, help="Debug mode")
parser.add_argument('input', type=str, help="Path to input directory of Markdown files")
args = parser.parse_args()

DB_NAME = args.output
DB = sqlite3.connect(database=DB_NAME)

path = args.input

def debug(msg):
    if args.debug:
        print(msg)

srcLinkPattern = re.compile('<a class="entityLink".*</a>')
def makeSearchText(section):
    return buffer(re.sub(srcLinkPattern, "", section))

def sections(path):
    pattern = re.compile('<a name="(.*)"></a>')

    for packageName in os.listdir(path):
        for filePath in glob.glob(os.path.join(path, packageName, "*.md")):
            debug("Indexing " + filePath)
            with open(filePath, 'r') as f:
                section = ""
                tag = os.path.basename(filePath)
                for line in f.readlines():
                    result = pattern.match(line)
                    if result:
                        section = makeSearchText(section)
                        tag = result.group(1)
                        yield packageName, tag, section
                        section = ""
                    else:
                        section += line

def load_db():
    """Add sample data to the database"""

    ins = """INSERT INTO fulltext_search(package, tag, doc) VALUES(?, ?, ?);"""

    for (packageName, tag, section) in sections(path):
        DB.execute(ins, (packageName, tag, section))

    DB.commit()

def init_db():
    """Initialize our database"""
    DB.execute("DROP TABLE IF EXISTS fulltext_search")
    DB.execute("""CREATE VIRTUAL TABLE fulltext_search USING fts4(
            id SERIAL,
            package TEXT,
            tag TEXT,
            doc TEXT,
            tokenize=porter
        );""")

if __name__ == "__main__":
    init_db()
    load_db()
    DB.close()

# chopshop-jev — advisory annotation layer (never decisive)
test:
    python3 -m unittest discover -s tests -v
clean:
    find . -name __pycache__ -type d -exec rm -rf {} +

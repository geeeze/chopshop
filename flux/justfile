# chopshop-flux — generation layer (diffusers; torch optional for guards)
# Uses the repo venv: the ambient PYTHONPATH leaks a py3.14 numpy that breaks pytest.
test:
    ./.venv/bin/python -m pytest -q
clean:
    find . -name __pycache__ -type d -exec rm -rf {} +

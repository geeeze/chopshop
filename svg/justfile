# chopshop-svg — T-shirt print pipeline (VTracer; Layer A + Layer B)
#
# The venv runs Python 3.13 + vtracer 0.6.15, matching the deployed Docker
# runner exactly. Do NOT run it on the system Python 3.14: vtracer's C
# extension segfaults on 3.14 for any colormode=color trace (the poster/photo
# presets), which crashes the whole sweep. The container is 3.13 and works.
#
# PYTHONPATH is cleared explicitly because this box exports an ambient
# PYTHONPATH pointing at a 3.14 site-packages (Hermes' own venv). Left set, it
# shadows the repo venv's numpy/Pillow with 3.14 builds and pytest dies on an
# import mismatch — the same leak, two different symptoms.
test:
    env -u PYTHONPATH ./.venv/bin/python -m pytest -q

# One file / one test, for a fast inner loop:
test-file FILE:
    env -u PYTHONPATH ./.venv/bin/python -m pytest -q {{FILE}}

clean:
    find . -name __pycache__ -type d -exec rm -rf {} +

@echo off
rem Builds main.pdf (needs MiKTeX or TeX Live with acmart, pgfplots, algorithm2e)
cd /d "%~dp0"
pdflatex -interaction=nonstopmode main && bibtex main && pdflatex -interaction=nonstopmode main && pdflatex -interaction=nonstopmode main

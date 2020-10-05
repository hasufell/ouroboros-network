#!/bin/bash

while inotifywait report.tex chapters/*.tex references.bib
do
  pdflatex -halt-on-error report.tex 
  bibtex report
  pdflatex -halt-on-error report.tex
  pdflatex -halt-on-error report.tex
done

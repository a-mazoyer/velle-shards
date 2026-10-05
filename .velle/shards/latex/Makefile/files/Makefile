project={{project}}

all:$(project).pdf

LATEXMK := $(shell command -v latexmk 2> /dev/null)

.PHONY: all clean $(project) $(project).pdf

$(project): $(project).pdf

$(project).pdf:
ifndef LATEXMK
	pdflatex $(project).tex
	pdflatex $(project).tex
	bibtex $(project)
	pdflatex $(project).tex
else
	"latexmk" -pdf -synctex=1 $(project).tex
endif

clean:
	rm -rf *.out *.dvi *.log *.out *.aux $(project).pdf *.bbl *.blg *.fdb_latexmk *.glo *.glsdefs *.ist *.synctex *.thm *.toc *.tdo *.fls

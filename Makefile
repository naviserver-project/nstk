ifndef NAVISERVER
    NAVISERVER  = /usr/local/ns
endif

include  $(NAVISERVER)/include/Makefile.module

demodir	 = $(INSTSRVPAG)/nstk

install:
	$(INSTALL_DATA) nstk.tcl $(INSTTCL)/
	$(MKDIR) $(demodir)
	for f in *.adp index.tcl include.tcl; do \
		test -f $(demodir)/$$f || $(INSTALL_DATA) $$f $(demodir)/; \
	done

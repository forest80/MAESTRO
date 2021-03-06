f90sources += actual_network.f90
f90sources += actual_burner.f90
f90sources += actual_rhs.f90

# network.f90 is created at build time for this network
actual_network.f90:   $(GENERAL_NET_INPUTS) $(MAESTRO_TOP_DIR)/Microphysics/networks/general_null/network.template
	@echo " "
	@echo "${bold}WRITING actual_network.f90${normal}"
	$(MAESTRO_TOP_DIR)/Microphysics/networks/general_null/write_network.py \
            -t $(MAESTRO_TOP_DIR)/Microphysics/networks/general_null/network.template \
            -s $(GENERAL_NET_INPUTS) \
            -o actual_network.f90
	@echo " "


# remove actual_network.f90 for 'make clean' and therefore 'make realclean'
# network.f90 is here for backwards compatibility -- remove this once the 
# microphysics merge is ancient memory
clean::
	$(RM) actual_network.f90
	$(RM) network.f90

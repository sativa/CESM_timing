




      module chem_mods
!--------------------------------------------------------------
! ... Basic chemistry parameters and arrays
!--------------------------------------------------------------

      use shr_kind_mod, only : r8 => shr_kind_r8

      implicit none

      save

      integer, parameter :: phtcnt = 117, & ! number of photolysis reactions
                            rxntot = 477, & ! number of total reactions
                            gascnt = 360, & ! number of gas phase reactions
                            nabscol = 2, & ! number of absorbing column densities
                            gas_pcnst = 174, & ! number of "gas phase" species
                            nfs = 2, & ! number of "fixed" species
                            relcnt = 0, & ! number of relationship species
                            grpcnt = 0, & ! number of group members
                            nzcnt = 1555, & ! number of non-zero matrix entries
                            extcnt = 14, & ! number of species with external forcing
                            clscnt1 = 23, & ! number of species in explicit class
                            clscnt2 = 0, & ! number of species in hov class
                            clscnt3 = 0, & ! number of species in ebi class
                            clscnt4 = 151, & ! number of species in implicit class
                            clscnt5 = 0, & ! number of species in rodas class
                            indexm = 1, & ! index of total atm density in invariant array
                            indexh2o = 0, & ! index of water vapor density
                            clsze = 1, & ! loop length for implicit chemistry
                            rxt_tag_cnt = 477, &
                            enthalpy_cnt = 41, &
                            nslvd = 0

      integer :: clscnt(5) = 0
      integer :: cls_rxt_cnt(4,5) = 0
      integer :: clsmap(gas_pcnst,5) = 0
      integer :: permute(gas_pcnst,5) = 0

      integer :: diag_map(clscnt4) = 0



      real(r8) :: adv_mass(gas_pcnst) = 0._r8
      real(r8) :: crb_mass(gas_pcnst) = 0._r8
      real(r8) :: fix_mass(max(1,nfs))



      real(r8), allocatable :: cph_enthalpy(:)
      integer, allocatable :: cph_rid(:)

      integer, allocatable :: rxt_tag_map(:)
      real(r8), allocatable :: pht_alias_mult(:,:)
      character(len=16), allocatable :: rxt_tag_lst(:)
      character(len=16), allocatable :: pht_alias_lst(:,:)
      character(len=16) :: inv_lst(max(1,nfs))
      character(len=16) :: extfrc_lst(max(1,extcnt))
      logical :: frc_from_dataset(max(1,extcnt))
      character(len=16) :: slvd_lst(max(1,nslvd))

      end module chem_mods

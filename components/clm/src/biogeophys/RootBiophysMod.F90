module RootBiophysMod

#include "shr_assert.h"

  !-------------------------------------------------------------------------------------- 
  ! DESCRIPTION:
  ! module contains subroutine for root biophysics
  !
  ! HISTORY
  ! created by Jinyun Tang, Mar 1st, 2014
  implicit none
  private
  !
  public  :: init_vegrootfr
  public  :: init_rootprof
  private :: zeng2001_rootfr
  private :: jackson1996_rootfr
  private :: exponential_rootfr

  integer, parameter :: zeng_2001_root = 0    !the zeng 2001 root profile function
  integer, parameter :: jackson_1996_root = 1 !the jackson 1996 root profile function
  integer, parameter :: koven_exp_root = 2    !the koven exponential root profile function

  integer, public :: rooting_profile_method   !select the type of rooting profile parameterization   
  !-------------------------------------------------------------------------------------- 

contains

  !-------------------------------------------------------------------------------------- 
  subroutine init_rootprof(NLFilename)
    !
    !DESCRIPTION
    ! initialize methods for root profile calculation

    ! !USES:
    use abortutils      , only : endrun   
    use fileutils       , only : getavu, relavu
    use spmdMod         , only : mpicom, masterproc
    use shr_mpi_mod     , only : shr_mpi_bcast
    use clm_varctl      , only : iulog
    use clm_nlUtilsMod  , only : find_nlgroup_name

    ! !ARGUMENTS:
    !------------------------------------------------------------------------------
    implicit none
    character(len=*), intent(in) :: NLFilename

    integer            :: nu_nml                     ! unit for namelist file
    integer            :: nml_error                  ! namelist i/o error flag
    character(*), parameter    :: subName = "('init_rootprof')"

    !-----------------------------------------------------------------------

! MUST agree with name in namelist and read statement
    namelist /rooting_profile_inparm/ rooting_profile_method

    ! Default values for namelist

    rooting_profile_method = zeng_2001_root

    ! Read rooting_profile namelist
    if (masterproc) then
       nu_nml = getavu()
       open( nu_nml, file=trim(NLFilename), status='old', iostat=nml_error )
       call find_nlgroup_name(nu_nml, 'rooting_profile_inparm', status=nml_error)
       if (nml_error == 0) then
          read(nu_nml, nml=rooting_profile_inparm,iostat=nml_error)
          if (nml_error /= 0) then
             call endrun(subname // ':: ERROR reading rooting_profile namelist')
          end if
       end if
       close(nu_nml)
       call relavu( nu_nml )

    endif

    call shr_mpi_bcast(rooting_profile_method, mpicom)

    if (masterproc) then

       write(iulog,*) ' '
       write(iulog,*) 'rooting_profile settings:'
       write(iulog,*) '  rooting_profile_method  = ',rooting_profile_method

    endif

!    rooting_profile_method = zeng_2001_root

  end subroutine init_rootprof

  !-------------------------------------------------------------------------------------- 
  subroutine init_vegrootfr(bounds, nlevsoi, nlevgrnd, rootfr)
    !
    !DESCRIPTION
    !initialize plant root profiles
    !
    ! USES
    use shr_kind_mod   , only : r8 => shr_kind_r8   
    use shr_assert_mod , only : shr_assert
    use shr_log_mod    , only : errMsg => shr_log_errMsg
    use decompMod      , only : bounds_type
    use abortutils     , only : endrun         
        use ColumnType            , only : col                
    use PatchType             , only : patch                
        !
    ! !ARGUMENTS:
    type(bounds_type), intent(in) :: bounds                     ! bounds
    integer,           intent(in) :: nlevsoi                    ! number of hydactive layers
    integer,           intent(in) :: nlevgrnd                   ! number of soil layers
    real(r8),          intent(out):: rootfr(bounds%begp: , 1: ) !
    !
    ! !LOCAL VARIABLES:
    character(len=32) :: subname = 'init_vegrootfr'  ! subroutine name
    integer           :: c,p
!scs    
    !------------------------------------------------------------------------

    SHR_ASSERT_ALL((ubound(rootfr) == (/bounds%endp, nlevgrnd/)), errMsg(__FILE__, __LINE__))

    select case (rooting_profile_method)
    case (zeng_2001_root)
       rootfr(bounds%begp:bounds%endp, 1 : nlevsoi) = zeng2001_rootfr(bounds, nlevsoi)

    case (jackson_1996_root)
       rootfr(bounds%begp:bounds%endp, 1 : nlevsoi) = jackson1996_rootfr(bounds, nlevsoi)
    case (koven_exp_root)
       rootfr(bounds%begp:bounds%endp, 1 : nlevsoi) = exponential_rootfr(bounds, nlevsoi)
       !jackson root, 1996, to be defined later
       !rootfr(bounds%begp:bounds%endp, 1 : ubj) = jackson1996_rootfr(bounds, ubj, pcolumn, ivt, zi)
       !case (schenk_jackson_2002_root)
       !schenk and Jackson root, 2002, to be defined later
       !rootfr(bounds%begp:bounds%endp, 1 : ubj) = schenk2002_rootfr(bounds, ubj, pcolumn, ivt, zi)        
    case default
       call endrun(subname // ':: a root fraction function must be specified!')   
    end select
    rootfr(bounds%begp:bounds%endp,nlevsoi+1:nlevgrnd)=0._r8   

!scs: shift roots up above bedrock boundary (distribute equally to each layer)
!scs: may not matter if normalized later
    do p = bounds%begp,bounds%endp   
       c = patch%column(p)
       rootfr(p,1:col%nbedrock(c)) = rootfr(p,1:col%nbedrock(c)) &
            + sum(rootfr(p,col%nbedrock(c)+1:nlevsoi))/real(col%nbedrock(c))
       rootfr(p,col%nbedrock(c)+1:nlevsoi) = 0._r8
    enddo
  end subroutine init_vegrootfr

  !-------------------------------------------------------------------------   
  function zeng2001_rootfr(bounds, ubj) result(rootfr)
    !
    ! DESCRIPTION
    ! compute root profile for soil water uptake
    ! using equation from Zeng 2001, J. Hydrometeorology
    !
    ! USES
    use shr_kind_mod   , only : r8 => shr_kind_r8   
    use shr_assert_mod , only : shr_assert
    use shr_log_mod    , only : errMsg => shr_log_errMsg   
    use decompMod      , only : bounds_type
    use pftconMod      , only : noveg, pftcon
    use PatchType      , only : patch
    use ColumnType     , only : col
    !
    ! !ARGUMENTS:
    type(bounds_type) , intent(in)    :: bounds                  ! bounds
    integer           , intent(in)    :: ubj                     ! ubnd
    !
    ! !RESULT
    real(r8) :: rootfr(bounds%begp:bounds%endp , 1:ubj ) !
    !
    ! !LOCAL VARIABLES:
    integer :: p, lev, c
    !------------------------------------------------------------------------

    !(computing from surface, d is depth in meter):
    ! Y = 1 -1/2 (exp(-ad)+exp(-bd) under the constraint that
    ! Y(d =0.1m) = 1-beta^(10 cm) and Y(d=d_obs)=0.99 with
    ! beta & d_obs given in Zeng et al. (1998).   

    do p = bounds%begp,bounds%endp   

       if (patch%itype(p) /= noveg) then
          c = patch%column(p)
          do lev = 1, ubj-1
             rootfr(p,lev) = .5_r8*( &
                    exp(-pftcon%roota_par(patch%itype(p)) * col%zi(c,lev-1))  &
                  + exp(-pftcon%rootb_par(patch%itype(p)) * col%zi(c,lev-1))  &
                  - exp(-pftcon%roota_par(patch%itype(p)) * col%zi(c,lev  ))  &
                  - exp(-pftcon%rootb_par(patch%itype(p)) * col%zi(c,lev  )) )
          end do
          rootfr(p,ubj) = .5_r8*( &
                 exp(-pftcon%roota_par(patch%itype(p)) * col%zi(c,ubj-1))  &
               + exp(-pftcon%rootb_par(patch%itype(p)) * col%zi(c,ubj-1)) )

       else
          rootfr(p,1:ubj) = 0._r8
       endif

    enddo
    return

  end function zeng2001_rootfr

  !-------------------------------------------------------------------------   
  function jackson1996_rootfr(bounds, ubj) result(rootfr)
    !
    ! DESCRIPTION
    ! compute root profile for soil water uptake
    ! using equation from Jackson et al. 1996, Oec.
    !
    ! USES
    use shr_kind_mod   , only : r8 => shr_kind_r8   
    use shr_assert_mod , only : shr_assert
    use shr_log_mod    , only : errMsg => shr_log_errMsg   
    use decompMod      , only : bounds_type
    use pftconMod      , only : noveg, pftcon
    use PatchType      , only : patch
    use ColumnType     , only : col
    !
    ! !ARGUMENTS:
    type(bounds_type) , intent(in)    :: bounds                  ! bounds
    integer           , intent(in)    :: ubj                     ! ubnd
    !
    ! !RESULT
    real(r8) :: rootfr(bounds%begp:bounds%endp , 1:ubj ) !
    !
    ! !LOCAL VARIABLES:
    real, parameter :: m_to_cm = 1.e2_r8
    real :: beta !patch specific shape parameter
    integer :: p, lev, c
    !------------------------------------------------------------------------

    !(computing from surface, d is depth in centimeters):
    ! Y = (1 - beta^d); beta given in Jackson et al. (1996).   

    rootfr(bounds%begp:bounds%endp, :)     = 0._r8
    do p = bounds%begp,bounds%endp   
       c = patch%column(p)       
       if (patch%itype(p) /= noveg) then
          beta = pftcon%rootprof_beta(patch%itype(p))
          do lev = 1, ubj
             rootfr(p,lev) = ( &
                  beta ** (col%zi(c,lev-1)*m_to_cm) - &
                  beta ** (col%zi(c,lev)*m_to_cm) )
             
          end do
       else
          rootfr(p,:) = 0.
       endif
       
    enddo
    return

  end function jackson1996_rootfr

  !-------------------------------------------------------------------------   
  function exponential_rootfr(bounds, ubj) result(rootfr)
    !
    ! DESCRIPTION
    ! compute root profile for soil water uptake
    ! using equation from Koven
    !
    ! USES
    use shr_kind_mod   , only : r8 => shr_kind_r8   
    use shr_assert_mod , only : shr_assert
    use shr_log_mod    , only : errMsg => shr_log_errMsg   
    use decompMod      , only : bounds_type
    use pftconMod      , only : noveg, pftcon
    use PatchType      , only : patch
    use ColumnType     , only : col
    !
    ! !ARGUMENTS:
    type(bounds_type) , intent(in)    :: bounds                  ! bounds
    integer           , intent(in)    :: ubj                     ! ubnd
    !
    ! !RESULT
    real(r8) :: rootfr(bounds%begp:bounds%endp , 1:ubj ) !
    !
    ! !LOCAL VARIABLES:
    real(r8), parameter :: rootprof_exp  = 3.  ! how steep profile is for root C inputs (1/ e-folding depth) (1/m)      
    real(r8) :: norm
    integer :: p, lev, c

    !------------------------------------------------------------------------

    rootfr(bounds%begp:bounds%endp, :)     = 0._r8
    do p = bounds%begp,bounds%endp   
       c = patch%column(p)
       if (patch%itype(p) /= noveg) then
          do lev = 1, ubj
             rootfr(p,lev) = exp(-rootprof_exp * col%z(c,lev)) * col%dz(c,lev)
          end do
       else
          rootfr(p,1) = 0.
       endif
       norm = -1./rootprof_exp * (exp(-rootprof_exp * col%z(c,ubj)) - 1._r8)
       rootfr(p,:) = rootfr(p,:) / norm

    enddo

    return

  end function exponential_rootfr
  
end module RootBiophysMod

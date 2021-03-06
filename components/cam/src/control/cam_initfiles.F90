module cam_initfiles
!----------------------------------------------------------------------- 
! 
! Open, close, and provide access to the initial conditions and topography files.
! 
!-----------------------------------------------------------------------

use shr_kind_mod,     only: r8=>shr_kind_r8, cl=>shr_kind_cl
use spmd_utils,       only: masterproc
use pio,              only: file_desc_t
use cam_logfile,      only: iulog
use cam_abortutils,   only: endrun
 
implicit none
private
save

! Public methods

public :: &
   cam_initfiles_readnl, &! read namelist
   cam_initfiles_open,   &! open initial and topo files
   initial_file_get_id,  &! returns filehandle for initial file
   topo_file_get_id,     &! returns filehandle for topo file
   cam_initfiles_close     ! close initial and topo files

! Namelist inputs
logical :: use_topo_file = .true.
character(len=cl), public, protected :: ncdata = 'ncdata'     ! full pathname for initial dataset
character(len=cl), public, protected :: bnd_topo = 'bnd_topo' ! full pathname for topography dataset

real(r8), public, protected :: pertlim = 0.0_r8 ! maximum abs value of scale factor used to perturb
                                                ! initial values



type(file_desc_t), pointer :: fh_ini, fh_topo

!======================================================================= 
contains
!======================================================================= 

subroutine cam_initfiles_readnl(nlfile)

   use namelist_utils,  only: find_group_name
   use units,           only: getunit, freeunit
   use spmd_utils,      only: mpicom, mstrid=>masterprocid, mpir8=>mpi_real8, &
                              mpichar=>mpi_character, mpi_logical

   character(len=*), intent(in) :: nlfile  ! filepath for file containing namelist input

   ! Local variables
   integer :: unitn, ierr
   character(len=*), parameter :: sub = 'cam_initfiles_readnl'

   namelist /cam_initfiles_nl/ ncdata, use_topo_file, bnd_topo, pertlim
   !-----------------------------------------------------------------------------

   if (masterproc) then
      unitn = getunit()
      open( unitn, file=trim(nlfile), status='old' )
      call find_group_name(unitn, 'cam_initfiles_nl', status=ierr)
      if (ierr == 0) then
         read(unitn, cam_initfiles_nl, iostat=ierr)
         if (ierr /= 0) then
            call endrun(sub // ': FATAL: reading namelist')
         end if
      end if
      close(unitn)
      call freeunit(unitn)
   end if

   call mpi_bcast(ncdata, len(ncdata), mpichar, mstrid, mpicom, ierr)
   if (ierr /= 0) call endrun(sub//": FATAL: mpi_bcast: ncdata")
   call mpi_bcast(use_topo_file, 1, mpi_logical, mstrid, mpicom, ierr)
   if (ierr /= 0) call endrun(sub//": FATAL: mpi_bcast: use_topo_file")
   call mpi_bcast(bnd_topo, len(bnd_topo), mpichar, mstrid, mpicom, ierr)
   if (ierr /= 0) call endrun(sub//": FATAL: mpi_bcast: bnd_topo")
   call mpi_bcast(pertlim, 1, mpir8, mstrid, mpicom, ierr)
   if (ierr /= 0) call endrun(sub//": FATAL: mpi_bcast: pertlim")

   if (masterproc) then
      write(iulog,*) sub//' options:'
      write(iulog,*) '  Initial dataset is:    ', trim(ncdata)
      if (use_topo_file) then
         write(iulog,*) '  Topography dataset is: ', trim(bnd_topo)
      else
         write(iulog,*) '  Topography dataset not used: PHIS, SGH, SGH30, LANDM_COSLAT set to zero'
      end if

      write(iulog,*) &
         '  Maximum abs value of scale factor used to perturb initial conditions, pertlim= ', pertlim

#ifdef PERGRO
      write(iulog,*)'  The PERGRO CPP token is defined.'
#endif

   end if

end subroutine cam_initfiles_readnl

!======================================================================= 

subroutine cam_initfiles_open()

   ! Open the initial conditions and topography files.

   use ioFileMod,        only: getfil

   use cam_pio_utils,    only: cam_pio_openfile
   use pio,              only: pio_nowrite

   use readinitial,      only: read_initial

   character(len=256) :: ncdata_loc     ! filepath of initial file on local disk
   character(len=256) :: bnd_topo_loc   ! filepath of topo file on local disk
   !----------------------------------------------------------------------- 
   
   ! Open initial, topography, and landfrac datasets
   call getfil (ncdata, ncdata_loc)

   allocate(fh_ini)
   call cam_pio_openfile(fh_ini, ncdata_loc, PIO_NOWRITE)

   if (use_topo_file) then

      if (trim(bnd_topo) /= 'bnd_topo' .and. len_trim(bnd_topo) > 0) then
         allocate(fh_topo)
         call getfil(bnd_topo, bnd_topo_loc)
         call cam_pio_openfile(fh_topo, bnd_topo_loc, PIO_NOWRITE)
      else
         ! Allow topography data to be read from the initial file if topo file name
         ! is not provided.
         fh_topo => fh_ini
      end if
   else
      nullify(fh_topo)
   end if

   ! Check for consistent settings on initial dataset -- this is dycore
   ! dependent -- should move to dycore interface
   call read_initial (fh_ini)

end subroutine cam_initfiles_open

!======================================================================= 

function initial_file_get_id()
   type(file_desc_t), pointer :: initial_file_get_id
   initial_file_get_id => fh_ini
end function initial_file_get_id

!======================================================================= 

function topo_file_get_id()
   type(file_desc_t), pointer :: topo_file_get_id
   topo_file_get_id => fh_topo
end function topo_file_get_id

!======================================================================= 

subroutine cam_initfiles_close()

  use pio,          only: pio_closefile

  if (associated(fh_ini)) then

     if (associated(fh_topo)) then

        if (.not. associated(fh_ini, target=fh_topo)) then
           ! if fh_ini and fh_topo point to different objects then close fh_topo
           call pio_closefile(fh_topo)
           deallocate(fh_topo)
        end if
        ! if fh_topo is associated, but points to the same object as fh_ini
        ! then it just needs to be nullified.
        nullify(fh_topo)
     end if
     
     call pio_closefile(fh_ini)
     deallocate(fh_ini)
     nullify(fh_ini)

  end if
end subroutine cam_initfiles_close

!======================================================================= 

end module cam_initfiles

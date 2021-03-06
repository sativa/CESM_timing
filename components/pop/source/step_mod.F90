!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

 module step_mod

!BOP
! !MODULE: step_mod

! !DESCRIPTION:
!  Contains the routine for stepping the model forward one timestep
!
! !REVISION HISTORY:
!  SVN:$Id: step_mod.F90 74250 2015-10-15 19:14:39Z jet $
!
! !USES:

   use POP_KindsMod
   use POP_ErrorMod
   use POP_CommMod
   use POP_FieldMod
   use POP_GridHorzMod
   use POP_HaloMod

   use blocks
   use domain_size
   use domain
   use constants
   use prognostic
   use timers
   use grid
   use diagnostics
   use state_mod, only: state
   use time_management
   use baroclinic
   use barotropic
   use surface_hgt
   use tavg
   use forcing_fields
   use forcing
   use damping, only : ldamp_uv, damping_uv
   use forcing_shf
   use ice
   use passive_tracers
   use registry
   use communicate
   use io_types
   use budget_diagnostics
   use overflows
   use overflow_type

   implicit none
   private
   save

! !PUBLIC MEMBER FUNCTIONS:

   public :: step, init_step

!----------------------------------------------------------------------
!
!   module variables
!
!----------------------------------------------------------------------

   integer (POP_i4), private :: &
      timer_step,              &! timer number for step
      timer_baroclinic,        &! timer for baroclinic parts of step
      timer_barotropic,        &! timer for barotropic part  of step
      timer_3dupdate		! timer for the 3D update after baroclinic component

   integer (POP_i4) :: ierr

   real (POP_r8), allocatable, dimension(:,:), private :: WORK1

!EOP
!BOC
!EOC
!***********************************************************************

 contains

!***********************************************************************
!BOP
! !IROUTINE: step
! !INTERFACE:

 subroutine step(errorCode)

! !DESCRIPTION:
!  This routine advances the simulation on timestep.
!  It controls logic for leapfrog and/or Matsuno timesteps and performs
!  modified Robert filtering or time-averaging if selected.  
!  Prognostic variables are updated for 
!  the next timestep near the end of the routine.
!  On Matsuno steps, the time (n) velocity and tracer arrays
!  UBTROP,VBTROP,UVEL,VVEL,TRACER contain the predicted new 
!  velocities from the 1st pass for use in the 2nd pass.
!
! !REVISION HISTORY:
!  same as module

!EOP
!BOC
!-----------------------------------------------------------------------
!
!  local or common variables:
!
!-----------------------------------------------------------------------
 
   integer (POP_i4) :: &
      errorCode

   integer (POP_i4) :: &
      i,j,k,n,           &! loop indices
      tmptime,           &! temp space for time index swapping
      iblock,            &! block counter
      ipass,             &! pass counter
      num_passes          ! number of passes through time step
                          ! (Matsuno requires two)
   integer (POP_i4) :: nn ! loop index, ovf_id
   integer (POP_i4) :: ovf_id

   real (POP_r8), dimension(nx_block,ny_block,max_blocks_clinic) :: &
      ZX,ZY,             &! vertically integrated forcing terms
      DH,DHU              ! time change of surface height minus
                          ! freshwater flux at T, U points

   real (POP_r8), dimension(nx_block,ny_block) :: &
      PSURF_FILT_OLD,    &! time filtered PSURF at oldtime
      PSURF_FILT_CUR,    &! time filtered PSURF at curtime
      WORK_MIN,WORK_MAX   ! work variables for enforcing tracer bounds during time filtering

   logical (POP_logical), save ::    &
      first_call = .true.          ! flag for initializing timers

   type (block) ::        &
      this_block          ! block information for current block

!-----------------------------------------------------------------------
!
!  start step timer
!
!-----------------------------------------------------------------------

   call timer_start(timer_step)

   errorCode = POP_Success

   lpre_time_manager = .true.

!-----------------------------------------------------------------------
!
!  Gather data for comparison with hydrographic data
!
!-----------------------------------------------------------------------
!
!  if(newday) call data_stations
!  if(newday .and. (mod(iday-1,3).eq.0) ) call data_slices
!
!-----------------------------------------------------------------------
!
!  Gather data for comparison with current meter data
!  THIS SECTION NOT FUNCTIONAL AT THIS TIME
!
!-----------------------------------------------------------------------
!
!  if(newday) call data_cmeters
!

!-----------------------------------------------------------------------
!
!     initialize the global budget arrays
!
!-----------------------------------------------------------------------

   call diag_for_tracer_budgets (tracer_mean_initial,volume_t_initial,  &
                                 step_call = .true.)


!-----------------------------------------------------------------------
!
!  read fields for surface forcing
!
!-----------------------------------------------------------------------

   call set_surface_forcing

   if (lidentical_columns) then

     !$OMP PARALLEL DO PRIVATE(iblock)
     do iblock = 1,nblocks_clinic
     
       STF(:,:,1,iblock) = global_SHF_coef * RCALCT(:,:,iblock) * hflux_factor
       STF(:,:,2,iblock) = c0 ! * RCALCT(:,:,iblock) * salinity_factor
     
       SHF_QSW(:,:,iblock) = c0 ! * RCALCT(:,:,iblock) * hflux_factor

       SMF(:,:,1,iblock) = global_taux * RCALCT(:,:,iblock)* momentum_factor
       SMF(:,:,2,iblock) = c0 ! * RCALCT(:,:,iblock)* momentum_factor

       SMFT(:,:,:,iblock) = SMF(:,:,:,iblock)

     end do
     !$OMP END PARALLEL DO

   end if

!-----------------------------------------------------------------------
!
!  update timestep counter, set corresponding model time, set
!  time-dependent logical switches to determine program flow.
!
!-----------------------------------------------------------------------

   call time_manager(registry_match('lcoupled'), liceform)

   lpre_time_manager = .false.

   call passive_tracers_send_time



!-----------------------------------------------------------------------
!
!  compute and initialize some time-average diagnostics
!
!-----------------------------------------------------------------------

   call tavg_set_flag(update_time=.true.)
   call tavg_forcing
   if (nt > 2) call passive_tracers_tavg_sflux(STF)
   call movie_forcing


!-----------------------------------------------------------------------
!
!  set timesteps and time-centering parameters for leapfrog or
!  matsuno steps.
!
!-----------------------------------------------------------------------

   mix_pass = 0
   if (matsuno_ts) then
      num_passes = 2
   else
      num_passes = 1
   endif


   do ipass = 1,num_passes



      if (matsuno_ts) mix_pass = mix_pass + 1

      if (leapfrogts) then  ! leapfrog (and averaging) timestep
         mixtime = oldtime
         beta  = alpha
         do k = 1,km
            c2dtt(k) = c2*dt(k)
         enddo
         c2dtu = c2*dtu
         c2dtp = c2*dtp    ! barotropic timestep = baroclinic timestep
         c2dtq = c2*dtu    ! turbulence timestep = mean flow timestep
      else
         mixtime = curtime
         beta  = theta
         do k = 1,km
            c2dtt(k) = dt(k)
         enddo
         c2dtu = dtu
         c2dtp = dtp       ! barotropic timestep = baroclinic timestep
         c2dtq = dtu       ! turbulence timestep = mean flow timestep
      endif

!-----------------------------------------------------------------------
!
!     on 1st pass of matsuno, set time (n-1) variables equal to
!     time (n) variables.
!
!-----------------------------------------------------------------------


      if (mix_pass == 1) then

         !$OMP PARALLEL DO PRIVATE(iblock)
         do iblock = 1,nblocks_clinic
            UBTROP(:,:,oldtime,iblock) = UBTROP(:,:,curtime,iblock)
            VBTROP(:,:,oldtime,iblock) = VBTROP(:,:,curtime,iblock)
            UVEL(:,:,:,oldtime,iblock) = UVEL(:,:,:,curtime,iblock)
            VVEL(:,:,:,oldtime,iblock) = VVEL(:,:,:,curtime,iblock)
            RHO (:,:,:,oldtime,iblock) = RHO (:,:,:,curtime,iblock)
            TRACER(:,:,:,:,oldtime,iblock) = &
            TRACER(:,:,:,:,curtime,iblock)
         end do
         !$OMP END PARALLEL DO

      endif


!-----------------------------------------------------------------------
!
!     initialize diagnostic flags and sums
!
!-----------------------------------------------------------------------

      call diag_init_sums

!-----------------------------------------------------------------------
!
!     calculate change in surface height dh/dt from surface pressure
!
!-----------------------------------------------------------------------

      call dhdt(DH,DHU)

      call ovf_reg_avgs_prd 

!-----------------------------------------------------------------------
!
!     Integrate baroclinic equations explicitly to find tracers and
!     baroclinic velocities at new time.  Update ghost cells for 
!     forcing terms leading into the barotropic solver.
!
!-----------------------------------------------------------------------

      if(profile_barrier) call POP_Barrier
      call timer_start(timer_baroclinic)
      call baroclinic_driver(ZX,ZY,DH,DHU, errorCode)
      if(profile_barrier) call POP_Barrier
      call timer_stop(timer_baroclinic)
      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error in baroclinic driver')
         return
      endif

!-----------------------------------------------------------------------
!
!     compute overflow transports
!
!-----------------------------------------------------------------------

      if( overflows_on ) then
         call ovf_driver
      endif
      if ( overflows_on .and. overflows_interactive ) then
         call ovf_rhs_brtrpc_momentum(ZX,ZY)
      endif

      call POP_HaloUpdate(ZX, POP_haloClinic, POP_gridHorzLocNECorner, &
                              POP_fieldKindVector, errorCode,          &
                              fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for ZX')
         return
      endif

      call POP_HaloUpdate(ZY, POP_haloClinic, POP_gridHorzLocNECorner, &
                              POP_fieldKindVector, errorCode,          &
                              fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for ZY')
         return
      endif

!-----------------------------------------------------------------------
!
!     Solve barotropic equations implicitly to find surface pressure
!     and barotropic velocities.
!
!-----------------------------------------------------------------------

      if(profile_barrier) call POP_Barrier

      if (.not.l1Ddyn) then

        call timer_start(timer_barotropic)
        call barotropic_driver(ZX,ZY,errorCode)
        if(profile_barrier) call POP_Barrier
        call timer_stop(timer_barotropic)

        if (errorCode /= POP_Success) then
           call POP_ErrorSet(errorCode, &
              'Step: error in barotropic')
           return
        endif

      end if

!-----------------------------------------------------------------------
!
!     update tracers using surface height at new time
!     also peform adjustment-like physics (convection, ice formation)
!
!-----------------------------------------------------------------------

      call timer_start(timer_baroclinic)
      call baroclinic_correct_adjust
      call timer_stop(timer_baroclinic)

      if ( overflows_on .and. overflows_interactive ) then
         call ovf_UV_solution
      endif

      if(profile_barrier) call POP_Barrier
      call timer_start(timer_3dupdate)

      call POP_HaloUpdate(UBTROP(:,:,newtime,:), &
                                  POP_haloClinic,                 &
                                  POP_gridHorzLocNECorner,        &
                                  POP_fieldKindVector, errorCode, &
                                  fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for UBTROP')
         return
      endif

      call POP_HaloUpdate(VBTROP(:,:,newtime,:), &
                                  POP_haloClinic,                 &
                                  POP_gridHorzLocNECorner,        &
                                  POP_fieldKindVector, errorCode, &
                                  fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for VBTROP')
         return
      endif

      call POP_HaloUpdate(UVEL(:,:,:,newtime,:), & 
                                POP_haloClinic,                 &
                                POP_gridHorzLocNECorner,        &
                                POP_fieldKindVector, errorCode, &
                                fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for UVEL')
         return
      endif

      call POP_HaloUpdate(VVEL(:,:,:,newtime,:), &
                                POP_haloClinic,                 &
                                POP_gridHorzLocNECorner,        &
                                POP_fieldKindVector, errorCode, &
                                fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for VVEL')
         return
      endif

      call POP_HaloUpdate(RHO(:,:,:,newtime,:), &
                               POP_haloClinic,                 &
                               POP_gridHorzLocCenter,          &
                               POP_fieldKindScalar, errorCode, &
                               fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for RHO')
         return
      endif

      call POP_HaloUpdate(TRACER(:,:,:,:,newtime,:), POP_haloClinic, &
                                  POP_gridHorzLocCenter,          &
                                  POP_fieldKindScalar, errorCode, &
                                  fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for TRACER')
         return
      endif

      call POP_HaloUpdate(QICE(:,:,:), &
                               POP_haloClinic,                 &
                               POP_gridHorzLocCenter,          &
                               POP_fieldKindScalar, errorCode, &
                               fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for QICE')
         return
      endif

      call POP_HaloUpdate(AQICE(:,:,:), &
                               POP_haloClinic,                 &
                               POP_gridHorzLocCenter,          &
                               POP_fieldKindScalar, errorCode, &
                               fillValue = 0.0_POP_r8)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'step: error updating halo for AQICE')
         return
      endif


      if(profile_barrier) call POP_Barrier
      call timer_stop(timer_3dupdate)

!-----------------------------------------------------------------------
!
!     add barotropic to baroclinic velocities at new time
!
!-----------------------------------------------------------------------

      !$OMP PARALLEL DO PRIVATE(iblock,k,i,j)
      do iblock = 1,nblocks_clinic

         if (l1Ddyn) then
           UBTROP(:,:,newtime,iblock) = c0     
           VBTROP(:,:,newtime,iblock) = c0     
         endif

!CDIR NOVECTOR
         do k=1,km
            do j=1,ny_block
            do i=1,nx_block
               if (k <= KMU(i,j,iblock)) then
                  UVEL(i,j,k,newtime,iblock) = &
                  UVEL(i,j,k,newtime,iblock) + UBTROP(i,j,newtime,iblock)
                  VVEL(i,j,k,newtime,iblock) = &
                  VVEL(i,j,k,newtime,iblock) + VBTROP(i,j,newtime,iblock)
               endif
            enddo
            enddo
         enddo

!-----------------------------------------------------------------------
!
!        Apply damping to UVEL and VVEL
!
!-----------------------------------------------------------------------

         if (ldamp_uv) then
           call damping_uv(UVEL(:,:,:,newtime,iblock),                        &
                           VVEL(:,:,:,newtime,iblock))
         end if

!-----------------------------------------------------------------------
!
!        on matsuno mixing steps update variables and cycle for 2nd pass
!        note: first step is forward only.
!
!-----------------------------------------------------------------------

         if (mix_pass == 1) then

            UBTROP(:,:,curtime,iblock) = UBTROP(:,:,newtime,iblock)
            VBTROP(:,:,curtime,iblock) = VBTROP(:,:,newtime,iblock)
            UVEL(:,:,:,curtime,iblock) = UVEL(:,:,:,newtime,iblock)
            VVEL(:,:,:,curtime,iblock) = VVEL(:,:,:,newtime,iblock)
            RHO (:,:,:,curtime,iblock) = RHO (:,:,:,newtime,iblock)
            TRACER(:,:,:,:,curtime,iblock) = &
            TRACER(:,:,:,:,newtime,iblock)

         endif
      enddo ! block loop
      !$OMP END PARALLEL DO

   end do ! ipass: cycle for 2nd pass in matsuno step

!-----------------------------------------------------------------------
!
!  extrapolate next guess for pressure from three known time levels
!
!-----------------------------------------------------------------------

   !$OMP PARALLEL DO PRIVATE(iblock)
   do iblock = 1,nblocks_clinic
      PGUESS(:,:,iblock) = c3*(PSURF(:,:,newtime,iblock) -   &
                               PSURF(:,:,curtime,iblock)) +  &
                               PSURF(:,:,oldtime,iblock)
   end do
   !$OMP END PARALLEL DO

!-----------------------------------------------------------------------
!
!  compute some global diagnostics 
!  before updating prognostic variables
!
!-----------------------------------------------------------------------

   call diag_global_preupdate(DH,DHU)

!-----------------------------------------------------------------------
!
!  update prognostic variables for next timestep:
!     on normal timesteps
!        (n) -> (n-1)
!        (n+1) -> (n) 
!     on averaging timesteps
!        [(n) + (n-1)]/2 -> (n-1)
!        [(n+1) + (n)]/2 -> (n)
!
!-----------------------------------------------------------------------

   if (avg_ts .or. back_to_back) then     ! averaging step

      !$OMP PARALLEL DO PRIVATE(iblock,this_block,k,n, &
      !$OMP                     PSURF_FILT_OLD,PSURF_FILT_CUR, &
      !$OMP                     WORK_MIN,WORK_MAX)

      do iblock = 1,nblocks_clinic
         this_block = get_block(blocks_clinic(iblock),iblock)  

         !*** avg 2-d fields

         UBTROP(:,:,oldtime,iblock) = p5*(UBTROP(:,:,oldtime,iblock) + & 
                                          UBTROP(:,:,curtime,iblock))
         VBTROP(:,:,oldtime,iblock) = p5*(VBTROP(:,:,oldtime,iblock) + &
                                          VBTROP(:,:,curtime,iblock))
         UBTROP(:,:,curtime,iblock) = p5*(UBTROP(:,:,curtime,iblock) + &
                                          UBTROP(:,:,newtime,iblock))
         VBTROP(:,:,curtime,iblock) = p5*(VBTROP(:,:,curtime,iblock) + &
                                          VBTROP(:,:,newtime,iblock))
         GRADPX(:,:,oldtime,iblock) = p5*(GRADPX(:,:,oldtime,iblock) + &
                                          GRADPX(:,:,curtime,iblock))
         GRADPY(:,:,oldtime,iblock) = p5*(GRADPY(:,:,oldtime,iblock) + &
                                          GRADPY(:,:,curtime,iblock))
         GRADPX(:,:,curtime,iblock) = p5*(GRADPX(:,:,curtime,iblock) + &
                                          GRADPX(:,:,newtime,iblock))
         GRADPY(:,:,curtime,iblock) = p5*(GRADPY(:,:,curtime,iblock) + &
                                          GRADPY(:,:,newtime,iblock))
         FW_OLD(:,:,iblock) = p5*(FW(:,:,iblock) + FW_OLD(:,:,iblock))

         !*** avg 3-d fields

         UVEL(:,:,:,oldtime,iblock) = p5*(UVEL(:,:,:,oldtime,iblock) + &
                                          UVEL(:,:,:,curtime,iblock))
         VVEL(:,:,:,oldtime,iblock) = p5*(VVEL(:,:,:,oldtime,iblock) + &
                                          VVEL(:,:,:,curtime,iblock))
         UVEL(:,:,:,curtime,iblock) = p5*(UVEL(:,:,:,curtime,iblock) + &
                                          UVEL(:,:,:,newtime,iblock))
         VVEL(:,:,:,curtime,iblock) = p5*(VVEL(:,:,:,curtime,iblock) + &
                                          VVEL(:,:,:,newtime,iblock))

         do n=1,nt

            do k=2,km
               TRACER(:,:,k,n,oldtime,iblock) =                &
                          p5*(TRACER(:,:,k,n,oldtime,iblock) + &
                              TRACER(:,:,k,n,curtime,iblock))
               TRACER(:,:,k,n,curtime,iblock) =                &
                          p5*(TRACER(:,:,k,n,curtime,iblock) + &
                              TRACER(:,:,k,n,newtime,iblock))
            end do
         end do

         if (sfc_layer_type == sfc_layer_varthick) then

            PSURF_FILT_OLD = p5*(PSURF(:,:,oldtime,iblock) + &
                                 PSURF(:,:,curtime,iblock))
            PSURF_FILT_CUR = p5*(PSURF(:,:,curtime,iblock) + &
                                 PSURF(:,:,newtime,iblock))

            do n = 1,nt
               WORK_MIN = min(TRACER(:,:,1,n,oldtime,iblock), TRACER(:,:,1,n,curtime,iblock))
               WORK_MAX = max(TRACER(:,:,1,n,oldtime,iblock), TRACER(:,:,1,n,curtime,iblock))

               TRACER(:,:,1,n,oldtime,iblock) =                   &
                   p5*((dz(1) + PSURF(:,:,oldtime,iblock)/grav)*  &
                       TRACER(:,:,1,n,oldtime,iblock) +           &
                       (dz(1) + PSURF(:,:,curtime,iblock)/grav)*  &
                       TRACER(:,:,1,n,curtime,iblock) ) 
               TRACER(:,:,1,n,oldtime,iblock) =                   &
                   TRACER(:,:,1,n,oldtime,iblock)/(dz(1) + PSURF_FILT_OLD/grav)

               where (TRACER(:,:,1,n,oldtime,iblock) < WORK_MIN) &
                   TRACER(:,:,1,n,oldtime,iblock) = WORK_MIN
               where (TRACER(:,:,1,n,oldtime,iblock) > WORK_MAX) &
                   TRACER(:,:,1,n,oldtime,iblock) = WORK_MAX


               WORK_MIN = min(TRACER(:,:,1,n,curtime,iblock), TRACER(:,:,1,n,newtime,iblock))
               WORK_MAX = max(TRACER(:,:,1,n,curtime,iblock), TRACER(:,:,1,n,newtime,iblock))

               TRACER(:,:,1,n,curtime,iblock) =                   &
                   p5*((dz(1) + PSURF(:,:,curtime,iblock)/grav)*  &
                       TRACER(:,:,1,n,curtime,iblock) +           &
                       (dz(1) + PSURF(:,:,newtime,iblock)/grav)*  &
                       TRACER(:,:,1,n,newtime,iblock) ) 
               TRACER(:,:,1,n,curtime,iblock) =                   &
                   TRACER(:,:,1,n,curtime,iblock)/(dz(1) + PSURF_FILT_CUR/grav)

               where (TRACER(:,:,1,n,curtime,iblock) < WORK_MIN) &
                   TRACER(:,:,1,n,curtime,iblock) = WORK_MIN
               where (TRACER(:,:,1,n,curtime,iblock) > WORK_MAX) &
                   TRACER(:,:,1,n,curtime,iblock) = WORK_MAX
            enddo

            PSURF(:,:,oldtime,iblock) = PSURF_FILT_OLD
            PSURF(:,:,curtime,iblock) = PSURF_FILT_CUR

         else

            do n=1,nt

               TRACER(:,:,1,n,oldtime,iblock) =                &
                          p5*(TRACER(:,:,1,n,oldtime,iblock) + &
                              TRACER(:,:,1,n,curtime,iblock))
               TRACER(:,:,1,n,curtime,iblock) =                &
                          p5*(TRACER(:,:,1,n,curtime,iblock) + &
                              TRACER(:,:,1,n,newtime,iblock))
            end do

            PSURF (:,:,oldtime,iblock) =                           &
                                  p5*(PSURF (:,:,oldtime,iblock) + &
                                      PSURF (:,:,curtime,iblock))
            PSURF (:,:,curtime,iblock) =                           &
                                  p5*(PSURF (:,:,curtime,iblock) + &
                                      PSURF (:,:,newtime,iblock))

         endif

         do k = 1,km  ! recalculate densities from averaged tracers
            call state(k,k,TRACER(:,:,k,1,oldtime,iblock), &
                           TRACER(:,:,k,2,oldtime,iblock), &
                           this_block,                     &
                         RHOOUT=RHO(:,:,k,oldtime,iblock))
            call state(k,k,TRACER(:,:,k,1,curtime,iblock), &
                           TRACER(:,:,k,2,curtime,iblock), &
                           this_block,                     &
                         RHOOUT=RHO(:,:,k,curtime,iblock))
         enddo 

         !*** correct after avg
         PGUESS(:,:,iblock) = p5*(PGUESS(:,:,iblock) + & 
                                   PSURF(:,:,newtime,iblock)) 
      end do ! block loop
      !$OMP END PARALLEL DO


   else if (lrobert_filter) then   ! robert filter

      !*** store tracer(curtime), prior to RF
      call diag_for_tracer_budgets_robert1

      !$OMP PARALLEL DO PRIVATE(iblock,this_block,k,n,WORK1)

      do iblock = 1,nblocks_clinic

         !*** filter UBTROP
         WORK1 = & 
         UBTROP(:,:,oldtime,iblock) + UBTROP(:,:,newtime,iblock) - c2*UBTROP(:,:,curtime,iblock)

         UBTROP(:,:,curtime,iblock) = UBTROP(:,:,curtime,iblock) + robert_curtime*WORK1
         UBTROP(:,:,newtime,iblock) = UBTROP(:,:,newtime,iblock) + robert_newtime*WORK1

         !*** filter VBTROP
         WORK1 = & 
         VBTROP(:,:,oldtime,iblock) + VBTROP(:,:,newtime,iblock) - c2*VBTROP(:,:,curtime,iblock)

         VBTROP(:,:,curtime,iblock) = VBTROP(:,:,curtime,iblock) + robert_curtime*WORK1
         VBTROP(:,:,newtime,iblock) = VBTROP(:,:,newtime,iblock) + robert_newtime*WORK1

         !*** filter GRADPX
         WORK1 = &
         GRADPX(:,:,oldtime,iblock) + GRADPX(:,:,newtime,iblock) - c2*GRADPX(:,:,curtime,iblock)

         GRADPX(:,:,curtime,iblock) = GRADPX(:,:,curtime,iblock) + robert_curtime*WORK1
         GRADPX(:,:,newtime,iblock) = GRADPX(:,:,newtime,iblock) + robert_newtime*WORK1

         !*** filter GRADPY
         WORK1 = &
         GRADPY(:,:,oldtime,iblock) + GRADPY(:,:,newtime,iblock) - c2*GRADPY(:,:,curtime,iblock)

         GRADPY(:,:,curtime,iblock) = GRADPY(:,:,curtime,iblock) + robert_curtime*WORK1
         GRADPY(:,:,newtime,iblock) = GRADPY(:,:,newtime,iblock) + robert_newtime*WORK1

         do k=1,km
         !*** UVEL
         WORK1 = &
         UVEL(:,:,k,oldtime,iblock) + UVEL(:,:,k,newtime,iblock) - c2*UVEL(:,:,k,curtime,iblock)

         UVEL(:,:,k,curtime,iblock) = UVEL(:,:,k,curtime,iblock) + robert_curtime*WORK1
         UVEL(:,:,k,newtime,iblock) = UVEL(:,:,k,newtime,iblock) + robert_newtime*WORK1

         !*** VVEL
         WORK1 = &
         VVEL(:,:,k,oldtime,iblock) + VVEL(:,:,k,newtime,iblock) - c2*VVEL(:,:,k,curtime,iblock)

         VVEL(:,:,k,curtime,iblock) = VVEL(:,:,k,curtime,iblock) + robert_curtime*WORK1
         VVEL(:,:,k,newtime,iblock) = VVEL(:,:,k,newtime,iblock) + robert_newtime*WORK1
         enddo ! k

         !*** TRACERS (interior)
         do n=1,nt
           do k=2,km
             WORK1 = &
             TRACER(:,:,k,n,oldtime,iblock) + TRACER(:,:,k,n,newtime,iblock) - c2*TRACER(:,:,k,n,curtime,iblock)

             TRACER(:,:,k,n,curtime,iblock) = TRACER(:,:,k,n,curtime,iblock) + robert_curtime*WORK1
             TRACER(:,:,k,n,newtime,iblock) = TRACER(:,:,k,n,newtime,iblock) + robert_newtime*WORK1
           enddo ! k
         enddo ! n

         !*** surface TRACERS & pressure
         if (sfc_layer_type == sfc_layer_varthick) then 
           do n=1,nt
             !*** k=1
               WORK1 = &
               (dz(1) + PSURF(:,:,oldtime,iblock)/grav)*TRACER(:,:,1,n,oldtime,iblock) +  &
               (dz(1) + PSURF(:,:,newtime,iblock)/grav)*TRACER(:,:,1,n,newtime,iblock) -  &
            c2*(dz(1) + PSURF(:,:,curtime,iblock)/grav)*TRACER(:,:,1,n,curtime,iblock)

               TRACER(:,:,1,n,curtime,iblock) = &
                (dz(1) + PSURF(:,:,curtime,iblock)/grav)*TRACER(:,:,1,n,curtime,iblock) + robert_curtime*WORK1
               TRACER(:,:,1,n,newtime,iblock) = &
                (dz(1) + PSURF(:,:,newtime,iblock)/grav)*TRACER(:,:,1,n,newtime,iblock) + robert_newtime*WORK1
           enddo ! n

           !*** PSURF
           WORK1= PSURF(:,:,oldtime,iblock) + PSURF(:,:,newtime,iblock) - c2*PSURF(:,:,curtime,iblock)
           PSURF(:,:,curtime,iblock) = PSURF(:,:,curtime,iblock) + robert_curtime*WORK1
           PSURF(:,:,newtime,iblock) = PSURF(:,:,newtime,iblock) + robert_newtime*WORK1

           do n=1,nt
             !*** k=1
               TRACER(:,:,1,n,curtime,iblock) = TRACER(:,:,1,n,curtime,iblock)/  &
                (dz(1) + PSURF(:,:,curtime,iblock)/grav)
               TRACER(:,:,1,n,newtime,iblock) = TRACER(:,:,1,n,newtime,iblock)/  &
                (dz(1) + PSURF(:,:,newtime,iblock)/grav)
           enddo ! n
         else
           !*** surface TRACER
           do n=1,nt
             !*** k=1
             WORK1 = &
             TRACER(:,:,1,n,oldtime,iblock) + TRACER(:,:,1,n,newtime,iblock) - c2*TRACER(:,:,1,n,curtime,iblock)

             TRACER(:,:,1,n,curtime,iblock) = TRACER(:,:,1,n,curtime,iblock) + robert_curtime*WORK1
             TRACER(:,:,1,n,newtime,iblock) = TRACER(:,:,1,n,newtime,iblock) + robert_newtime*WORK1
           enddo ! n

           !*** PSURF
           WORK1= PSURF(:,:,oldtime,iblock) + PSURF(:,:,newtime,iblock) - c2*PSURF(:,:,curtime,iblock)
           PSURF(:,:,curtime,iblock) = PSURF(:,:,curtime,iblock) + robert_curtime*WORK1
           PSURF(:,:,newtime,iblock) = PSURF(:,:,newtime,iblock) + robert_newtime*WORK1

         endif ! sfc_layer_type == sfc_layer_varthick

         this_block = get_block(blocks_clinic(iblock),iblock)
         do k = 1,km  ! recalculate densities from averaged tracers
            call state(k,k,TRACER(:,:,k,1,curtime,iblock), TRACER(:,:,k,2,curtime,iblock), &
                       this_block, RHOOUT=RHO(:,:,k,curtime,iblock))
            call state(k,k,TRACER(:,:,k,1,newtime,iblock), TRACER(:,:,k,2,newtime,iblock), &
                           this_block, RHOOUT=RHO(:,:,k,newtime,iblock))
         enddo !k



         !** same as standard leapfrog
         FW_OLD(:,:,iblock) = FW(:,:,iblock)

      end do ! block loop (iblock)
      !$OMP END PARALLEL DO

      !*** accumulate RF budget term
      call diag_for_tracer_budgets_robert2

      !*** update time indices just like standard leapfrog
      tmptime = oldtime
      oldtime = curtime
      curtime = newtime
      newtime = tmptime

      !*** MM version has additional indices -- check on these...

   else  ! non-averaging step
  
      !$OMP PARALLEL DO PRIVATE(iblock)
      do iblock = 1,nblocks_clinic

         if (mix_pass == 2) then ! reset time n variables on 2nd pass matsuno

            UBTROP(:,:,curtime,iblock) = UBTROP(:,:,oldtime,iblock)
            VBTROP(:,:,curtime,iblock) = VBTROP(:,:,oldtime,iblock)
            UVEL(:,:,:,curtime,iblock) = UVEL(:,:,:,oldtime,iblock)
            VVEL(:,:,:,curtime,iblock) = VVEL(:,:,:,oldtime,iblock)
            TRACER(:,:,:,:,curtime,iblock) = &
                                     TRACER(:,:,:,:,oldtime,iblock)
            RHO(:,:,:,curtime,iblock) = RHO(:,:,:,oldtime,iblock)

         endif

         FW_OLD(:,:,iblock) = FW(:,:,iblock)

      end do ! block loop
      !$OMP END PARALLEL DO


      tmptime = oldtime
      oldtime = curtime
      curtime = newtime
      newtime = tmptime

   endif


!-----------------------------------------------------------------------
!
!  end of timestep, all variables updated
!  compute and print some more diagnostics
!
!-----------------------------------------------------------------------

   if (registry_match('lcoupled')) then
   if ( liceform .and. check_time_flag(ice_cpl_flag) ) then
     call tavg_increment_sum_qflux(const=tlast_ice)
     !$OMP PARALLEL DO PRIVATE(iblock)
     do iblock = 1,nblocks_clinic
        call ice_flx_to_coupler(TRACER(:,:,:,:,curtime,iblock),iblock)
        call accumulate_tavg_field(QFLUX(:,:,iblock), tavg_id('QFLUX'),  &
                                   iblock,1,const=tlast_ice)
                                   
     end do ! block loop
     !$OMP END PARALLEL DO
!-----------------------------------------------------------------------
!    time-averaging for ice formation related quantities
!-----------------------------------------------------------------------
     if (nt > 2) call passive_tracers_tavg_FvICE(cp_over_lhfusion, QICE)
   endif
   endif

   call diag_global_afterupdate
   call diag_print
   call diag_transport

   if ( eod .and. ldiag_velocity) then
      call diag_velocity
   endif

   if (ldiag_global_tracer_budgets) call tracer_budgets

!-----------------------------------------------------------------------
!
!  stop step timer
!
!-----------------------------------------------------------------------

  call timer_stop(timer_step)

!-----------------------------------------------------------------------
!EOC

   end subroutine step

!***********************************************************************

!BOP
! !IROUTINE: init_step
! !INTERFACE:

 subroutine init_step

! !DESCRIPTION:
!  This routine initializes timers and flags used in subroutine step.
!
! !REVISION HISTORY:
!  added 17 August 2007 njn01

!EOP
!BOC

!-----------------------------------------------------------------------
!
!  initialize timers
!
!-----------------------------------------------------------------------

   call get_timer(timer_step,'OCN:STEP',1,distrb_clinic%nprocs)
   call get_timer(timer_baroclinic,'OCN:BAROCLINIC',1,distrb_clinic%nprocs)
   call get_timer(timer_barotropic,'OCN:PBAROTROPIC',1,distrb_clinic%nprocs)
   call get_timer(timer_3dupdate,'OCN:3D-UPDATE',1,distrb_clinic%nprocs)

!-----------------------------------------------------------------------
!
!  allocate Robert-filter work array
!
!-----------------------------------------------------------------------
   if (lrobert_filter) then
      allocate (WORK1(nx_block,ny_block))
      WORK1 = c0
   endif

!-----------------------------------------------------------------------
!EOC

   end subroutine init_step
 end module step_mod

!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

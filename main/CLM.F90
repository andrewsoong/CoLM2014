#include <define.h>

  PROGRAM CLM
! ======================================================================
! Reference: 
!     [1] Dai et al., 2003: The Common Land Model (CoLM). 
!         Bull. of Amer. Meter. Soc., 84: 1013-1023
!     [2] Dai et al., 2004: A two-big-leaf model for canopy temperature,
!         photosynthesis and stomatal conductance. J. Climate, 17: 2281-2299.
!     [3] Dai et al., 2014: The Terrestrial Modeling System (TMS).
!     [4] Dai Yamazaki, 2014: The global river model CaMa-Flood (version 3.6.2)
!
!     Created by Yongjiu Dai, Februay 2004
!     Revised by Yongjiu Dai and Hua Yuan, April 2014
! ======================================================================

      use precision
      use PhysicalConstants
      use MOD_TimeInvariants
      use MOD_TimeVariables
      use MOD_1D_Forcing
      use MOD_2D_Forcing
      use MOD_1D_Fluxes
      use MOD_2D_Fluxes
      use timemanager
      use GETMETMOD
      use omp_lib

#if(defined CaMa_Flood)
      use parkind1   ,only: jpim, jprm
      use mod_input  ,only: lognam, nxin, nyin
      use mod_map    ,only: regionall, regionthis
      use mod_output ,only: csufbin, csufvec, csufcdf
#endif

      IMPLICIT NONE

! ----------------local variables ---------------------------------
#if(defined USGS_CLASSIFICATION)
      integer, parameter :: N_land_classification = 24 ! GLCC USGS number of land cover category
#endif
#if(defined IGBP_CLASSIFICATION)
      integer, parameter :: N_land_classification = 17 ! MODIS IGBP number of land cover category
#endif
      integer, parameter :: nl_soil  = 10   ! number of soil layers
      integer, parameter :: nl_lake  = 10   ! number of lake layers
      integer, parameter :: maxsnl   = -5   ! max number of snow layers
      integer, parameter :: maxpatch = N_land_classification + 1   ! max number of patches in a grid

      character(LEN=256) :: site  ! site name
      integer :: lon_points       ! number of longitude points on model grids
      integer :: lat_points       ! number of latitude points on model grids
      integer :: numpatch         ! total number of patches of model grids
      integer :: idate(3)         ! calendar (year, julian day, seconds)
      integer :: edate(3)         ! calendar (year, julian day, seconds)
      integer :: pdate(3)         ! calendar (year, julian day, seconds)
      real(r8):: deltim           ! time step (senconds)
      logical :: solarin_all_band ! downward solar in broad band
      logical :: greenwich        ! greenwich time
      character(len=256) :: dir_model_landdata
      character(len=256) :: dir_forcing
      character(len=256) :: dir_output
      character(len=256) :: dir_restart_hist
                                  !
      logical :: doalb            ! true => start up the surface albedo calculation
      logical :: dolai            ! true => start up the time-varying vegetation paramter
      logical :: dosst            ! true => update sst/ice/snow
      logical :: lwrite           ! true: write output  file frequency
      logical :: rwrite           ! true: write restart file frequency
                                  !
      integer :: istep            ! looping step
      integer :: nac              ! number of accumulation
      integer,  allocatable :: nac_ln(:,:)      ! number of accumulation for local noon time virable
      real(r8), allocatable :: oro(:)           ! ocean(0)/seaice(2)/ flag
      real(r8), allocatable :: a_rnof(:,:)      ! total runoff [mm/s]
      integer :: Julian_1day_p, Julian_1day 
      integer :: Julian_8day_p, Julian_8day 
      integer :: s_year, s_julian, s_seconds
      integer :: e_year, e_julian, e_seconds
      integer :: p_year, p_julian, p_seconds
      integer :: i, j

      type(timestamp) :: itstamp, etstamp, ptstamp

#if(defined CaMa_Flood)
      integer(kind=jpim) :: iyyyy, imm, idd          ! start date
      integer(kind=jpim) :: eyyyy, emm, edd          ! end date
      real(kind=jprm), allocatable :: r2roffin(:,:)  ! input runoff (mm/day)
#ifdef usempi
      include 'mpif.h'
      integer(kind=jpim) :: ierr, nproc, nid
#endif
#endif

      namelist /clmexp/ site,                   &!1
                        dir_model_landdata,     &!2
                        dir_forcing,            &!3
                        dir_output,             &!4
                        dir_restart_hist,       &!5
                        lon_points,             &!6
                        lat_points,             &!7
                        deltim,                 &!8
                        solarin_all_band,       &!9
                        e_year,                 &!10
                        e_julian,               &!11
                        e_seconds,              &!12
                        p_year,                 &!13
                        p_julian,               &!14
                        p_seconds,              &!15
                        numpatch,               &!16
                        greenwich,              &!17
                        s_year,                 &!18
                        s_julian,               &!19
                        s_seconds                !20
! ======================================================================
!     define the run and open files (for off-line use)

      read(5,clmexp) 

      call initimetype(greenwich)

      idate(1) = s_year; idate(2) = s_julian; idate(3) = s_seconds
      edate(1) = e_year; edate(2) = e_julian; edate(3) = e_seconds
      pdate(1) = p_year; pdate(2) = p_julian; pdate(3) = p_seconds
      
      call adj2end(edate)
      call adj2end(pdate)
      
      itstamp = idate
      etstamp = edate
      ptstamp = pdate

      call allocate_TimeInvariants(nl_soil,nl_lake,numpatch,lon_points,lat_points)
      call allocate_TimeVariables (nl_soil,nl_lake,maxsnl,numpatch)
      call allocate_1D_Forcing    (numpatch)
      call allocate_2D_Forcing    (lon_points,lat_points)
      call allocate_1D_Fluxes     (numpatch)
      call allocate_2D_Fluxes     (lon_points,lat_points,nl_soil,maxsnl,nl_lake)
 
      call FLUSH_2D_Fluxes

      allocate (oro(numpatch)) 
      allocate (nac_ln(lon_points,lat_points))
! ----------------------------------------------------------------------
    ! Read in the model time invariant constant data
      CALL READ_TimeInvariants(dir_restart_hist,site)

    ! Read in the model time varying data (model state variables)
      CALL READ_TimeVariables (idate,dir_restart_hist,site)


!-----------------------
#if(defined CaMa_Flood)
#if(defined usempi)
      call mpi_init(ierr)
      call mpi_comm_size(mpi_comm_world, nproc, ierr)
      call mpi_comm_rank(mpi_comm_world, nid, ierr)
      regionall =nproc
      regionthis=nid+1
#endif

      if (regionall>=2 )then                            !! regional output for mpi run
        write(csufbin,'(a5,i2.2)') '.bin-', regionthis  !! change suffix of output file for each calculation node
        write(csufvec,'(a5,i2.2)') '.vec-', regionthis
        write(csufcdf,'(a4,i2.2)') '.nc-',  regionthis
      endif

      iyyyy = s_year
      eyyyy = e_year
      CALL julian2monthday(s_year,s_julian,imm,idd)
      CALL julian2monthday(e_year,e_julian,emm,edd)
      CALL CaMaINI(iyyyy,imm,idd,eyyyy,emm,edd)

      nxin = lon_points
      nyin = lat_points
      allocate (r2roffin(nxin,nyin))  !! input runoff (mm/day)
#endif
      allocate (a_rnof(lon_points,lat_points))
!-----------------------

      doalb = .true.
      dolai = .true.
      dosst = .false.
      oro(:) = 1.


    ! Initialize meteorological forcing data module
      CALL GETMETINI(dir_forcing, deltim, lat_points, lon_points)


! ======================================================================
! begin time stepping loop
! ======================================================================

      nac = 0; nac_ln(:,:) = 0
      istep = 1

      TIMELOOP : DO while (itstamp < etstamp)
print*, 'TIMELOOP = ', istep

         Julian_1day_p = int(calendarday(idate)-1)/1*1 + 1
         Julian_8day_p = int(calendarday(idate)-1)/8*8 + 1

       ! Read in the meteorological forcing
       ! ----------------------------------------------------------------------
         CALL rd_forcing(idate,lon_points,lat_points,solarin_all_band,numpatch)

       ! Calendar for NEXT time step
       ! ----------------------------------------------------------------------
         CALL TICKTIME (deltim,idate)
         itstamp = itstamp + int(deltim)

       ! Call clm driver
       ! ----------------------------------------------------------------------
         CALL CLMDRIVER (nl_soil,maxsnl,nl_lake,numpatch,idate,deltim,&
                         dolai,doalb,dosst,oro)

       ! Get leaf area index
       ! ----------------------------------------------------------------------
#if(!defined DYN_PHENOLOGY)
       ! READ in Leaf area index and stem area index
       ! Update every 8 days (time interval of the MODIS LAI data) 
       ! ----------------------------------------------------------------------
         Julian_8day = int(calendarday(idate)-1)/8*8 + 1
         if(Julian_8day /= Julian_8day_p)then
            CALL LAI_readin (lon_points,lat_points,&
                             Julian_8day,numpatch,dir_model_landdata)
         endif
#else
       ! Update once a day
         dolai = .false.
         Julian_1day = int(calendarday(idate)-1)/1*1 + 1
         if(Julian_1day /= Julian_1day_p)then
            dolai = .true.
         endif
#endif

       ! Mapping subgrid patch [numpatch] vector of subgrid points to 
       !     -> [lon_points]x[lat_points] grid average
       ! ----------------------------------------------------------------------
         CALL vec2xy (lon_points,lat_points,numpatch,nl_soil,maxsnl,&
                      nl_lake,nac,nac_ln,a_rnof)

         do j = 1, lat_points
            do i = 1, lon_points
               if(a_rnof(i,j) < 1.e-10) a_rnof(i,j) = 0.
            enddo
         enddo

#if(defined CaMa_Flood)
       ! Simulating the hydrodynamics in continental-scale rivers
       ! ----------------------------------------------------------------------

         r2roffin(:,:) = a_rnof(:,:)*86400.  ! total runoff [mm/s] -> [mm/day]
         CALL CaMaMAIN(iyyyy,imm,idd,istep,r2roffin)

#endif

       ! Logical idenfication for writing output and restart file
         lwrite = .false.
         rwrite = .false.
         CALL lpwrite(idate,deltim,lwrite,rwrite)

       ! Write out the model variables for restart run and the histroy file
       ! ----------------------------------------------------------------------
         if ( lwrite ) then

            if ( .NOT. (itstamp<=ptstamp) ) then
               CALL flxwrite (idate,nac,nac_ln,lon_points,lat_points,nl_soil,maxsnl,nl_lake,dir_output,site)
            endif

          ! Setting for next time step 
          ! ----------------------------------------------------------------------
            call FLUSH_2D_Fluxes
            nac = 0; nac_ln(:,:) = 0
         endif

         if ( rwrite ) then
            if ( .NOT. (itstamp<=ptstamp) ) then
               CALL WRITE_TimeVariables (idate,dir_restart_hist,site)
            endif
         endif

         istep = istep + 1

      END DO TIMELOOP

      call deallocate_TimeInvariants
      call deallocate_TimeVariables 
      call deallocate_1D_Forcing 
      call deallocate_2D_Forcing 
      call deallocate_1D_Fluxes     
      call deallocate_2D_Fluxes     
 
      call GETMETFINAL

      deallocate (a_rnof) 
      deallocate (oro)
      deallocate (nac_ln)
#if(defined CaMa_Flood)
      deallocate (r2roffin)
      if (regionall>=2 )then
        close(lognam)
      endif
#ifdef usempi
      call mpi_finalize(ierr)
#endif
#endif

      write(6,*) 'CLM Execution Completed'

  END PROGRAM CLM
! ----------------------------------------------------------------------
! EOP

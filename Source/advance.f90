module advance_timestep_module

  use probin_module

  private

  public :: advance_timestep

contains
    
  subroutine advance_timestep(init_mode,mla,uold,sold,s1,s2,unew,snew,umac,uedge,sedge, &
                              utrans,sflux,gp,p,scal_force,normal,s0_old,s0_1,s0_2, &
                              s0_new,p0_old,p0_1,p0_2,p0_new,gam1,w0,eta,rho_omegadot1, &
                              rho_omegadot2,rho_Hext,div_coeff_old,div_coeff_new, &
                              grav_cell_old,dx,time,dt,dtold,the_bc_tower,anelastic_cutoff, &
                              verbose,mg_verbose,cg_verbose,dSdt,Source_old,Source_new, &
                              gamma1_term,sponge,do_sponge,hgrhs,istep)

    use ml_layout_module
    use bl_constants_module
    use multifab_module
    use pre_advance_module
    use velocity_advance_module
    use scalar_advance_module
    use macrhs_module
    use macproject_module
    use hgrhs_module
    use hgproject_module
    use proj_parameters
    use bc_module
    use box_util_module
    use make_div_coeff_module
    use make_w0_module
    use advect_base_module
    use react_base_module
    use react_state_module
    use make_S_module
    use average_module
    use phihalf_module
    use extraphalf_module
    use thermal_conduct_module
    use make_explicit_thermal_module
    use add_react_to_thermal_module
    use variables, only: nscal, press_comp, temp_comp, rho_comp
    use geometry, only: nr, spherical
    use network, only: nspec
    use make_grav_module
    use fill_3d_module
    use cell_to_edge_module
    use define_bc_module
    
    implicit none
    
    logical,         intent(in   ) :: init_mode
    type(ml_layout), intent(inout) :: mla
    type(multifab),  intent(inout) :: uold(:)
    type(multifab),  intent(inout) :: sold(:)
    type(multifab),  intent(inout) :: s1(:)
    type(multifab),  intent(inout) :: s2(:)
    type(multifab),  intent(inout) :: unew(:)
    type(multifab),  intent(inout) :: snew(:)
    type(multifab),  intent(inout) :: umac(:,:)
    type(multifab),  intent(inout) :: uedge(:,:)
    type(multifab),  intent(inout) :: sedge(:,:)
    type(multifab),  intent(inout) :: utrans(:,:)
    type(multifab),  intent(inout) :: sflux(:,:)
    type(multifab),  intent(inout) :: gp(:)
    type(multifab),  intent(inout) :: p(:)
    type(multifab),  intent(inout) :: scal_force(:)
    type(multifab),  intent(in   ) :: normal(:)
    real(dp_t)    ,  intent(inout) :: s0_old(:,0:,:)
    real(dp_t)    ,  intent(inout) :: s0_1(:,0:,:)
    real(dp_t)    ,  intent(inout) :: s0_2(:,0:,:)
    real(dp_t)    ,  intent(inout) :: s0_new(:,0:,:)
    real(dp_t)    ,  intent(inout) :: p0_old(:,0:)
    real(dp_t)    ,  intent(inout) :: p0_1(:,0:)
    real(dp_t)    ,  intent(inout) :: p0_2(:,0:)
    real(dp_t)    ,  intent(inout) :: p0_new(:,0:)
    real(dp_t)    ,  intent(inout) :: gam1(:,0:)
    real(dp_t)    ,  intent(inout) :: w0(:,0:)
    real(dp_t)    ,  intent(inout) :: eta(:,0:,:)
    type(multifab),  intent(inout) :: rho_omegadot1(:)
    type(multifab),  intent(inout) :: rho_omegadot2(:)
    type(multifab),  intent(inout) :: rho_Hext(:)
    real(dp_t)    ,  intent(in   ) :: div_coeff_old(:,0:)
    real(dp_t)    ,  intent(inout) :: div_coeff_new(:,0:)
    real(dp_t)    ,  intent(in   ) :: grav_cell_old(:,0:)
    real(dp_t)    ,  intent(in   ) :: dx(:,:),time,dt,dtold
    type(bc_tower),  intent(in   ) :: the_bc_tower
    real(dp_t)    ,  intent(in   ) :: anelastic_cutoff
    integer       ,  intent(in   ) :: verbose,mg_verbose,cg_verbose
    type(multifab),  intent(inout) :: dSdt(:)
    type(multifab),  intent(inout) :: Source_old(:)
    type(multifab),  intent(inout) :: Source_new(:)
    type(multifab),  intent(inout) :: gamma1_term(:)
    type(multifab),  intent(in   ) :: sponge(:)
    logical       ,  intent(in   ) :: do_sponge
    type(multifab),  intent(inout) :: hgrhs(:)
    integer       ,  intent(in   ) :: istep

    ! local
    type(multifab), allocatable :: rhohalf(:)
    type(multifab), allocatable :: w0_cart_vec(:)
    type(multifab), allocatable :: w0_force_cart_vec(:)
    type(multifab), allocatable :: macrhs(:)
    type(multifab), allocatable :: macphi(:)
    type(multifab), allocatable :: hgrhs_old(:)
    type(multifab), allocatable :: Source_nph(:)
    type(multifab), allocatable :: thermal(:)
    type(multifab), allocatable :: s2star(:)
    type(multifab), allocatable :: rho_omegadot2_hold(:)

    real(dp_t)    , allocatable :: grav_cell_nph(:,:)
    real(dp_t)    , allocatable :: grav_cell_new(:,:)
    real(dp_t)    , allocatable :: s0_nph(:,:,:)
    real(dp_t)    , allocatable :: w0_force(:,:)
    real(dp_t)    , allocatable :: w0_old(:,:)
    real(dp_t)    , allocatable :: Sbar(:,:,:)
    real(dp_t)    , allocatable :: div_coeff_nph(:,:)
    real(dp_t)    , allocatable :: div_coeff_edge(:,:)
    real(dp_t)    , allocatable :: rho_omegadotbar1(:,:,:)
    real(dp_t)    , allocatable :: rho_omegadotbar2(:,:,:)
    real(dp_t)    , allocatable :: rho_Hextbar(:,:,:)
    integer       , allocatable :: lo(:),hi(:)

    ! Only needed for spherical.eq.1 
    type(multifab) , allocatable :: div_coeff_3d(:)

    real(dp_t) :: halfdt,eps_in
    integer    :: j,n,dm,nlevs,ng_cell,proj_type
    logical    :: nodal(mla%dim)

    dm = mla%dim
    nlevs = size(uold)

    allocate(           rhohalf(nlevs))
    allocate(       w0_cart_vec(nlevs))
    allocate( w0_force_cart_vec(nlevs))
    allocate(            macrhs(nlevs))
    allocate(            macphi(nlevs))
    allocate(         hgrhs_old(nlevs))
    allocate(        Source_nph(nlevs))
    allocate(           thermal(nlevs))
    allocate(            s2star(nlevs))
    allocate(rho_omegadot2_hold(nlevs))
    if (spherical.eq.1) then
       allocate(div_coeff_3d(nlevs))
    endif

    allocate(   grav_cell_nph(nlevs,0:nr(nlevs)-1))
    allocate(   grav_cell_new(nlevs,0:nr(nlevs)-1))
    allocate(          s0_nph(nlevs,0:nr(nlevs)-1,nscal))
    allocate(        w0_force(nlevs,0:nr(nlevs)-1))
    allocate(          w0_old(nlevs,0:nr(nlevs)))
    allocate(            Sbar(nlevs,0:nr(nlevs)-1,1))
    allocate(   div_coeff_nph(nlevs,0:nr(nlevs)-1))
    allocate(  div_coeff_edge(nlevs,0:nr(nlevs)))
    allocate(rho_omegadotbar1(nlevs,0:nr(nlevs)-1,nspec))
    allocate(rho_omegadotbar2(nlevs,0:nr(nlevs)-1,nspec))
    allocate(     rho_Hextbar(nlevs,0:nr(nlevs)-1,1))

    allocate(lo(dm))
    allocate(hi(dm))

    nodal = .true.
    ng_cell = uold(1)%ng
    halfdt = half*dt
    
    ! This is always zero at the beginning of a time step
    eta(:,:,:) = ZERO

    ! Set w0_old to w0 from last time step.
    w0_old = w0

    do n = 1, nlevs
       call multifab_build(rhohalf(n),            mla%la(n), 1    , 1)
       call multifab_build(macrhs(n),             mla%la(n), 1    , 0)
       call multifab_build(macphi(n),             mla%la(n), 1    , 1)
       call multifab_build(hgrhs_old(n),          mla%la(n), 1    , 0, nodal)
       call multifab_build(Source_nph(n),         mla%la(n), 1    , 0)
       call multifab_build(thermal(n),            mla%la(n), 1    , 1)
       call multifab_build(s2star(n),             mla%la(n), nscal, ng_cell)
       call multifab_build(rho_omegadot2_hold(n), mla%la(n), nspec, 0)
       call setval(rhohalf(n)           , ZERO, all=.true.)
       call setval(macrhs(n)            , ZERO, all=.true.)
       call setval(macphi(n)            , ZERO, all=.true.)
       call setval(hgrhs_old(n)         , ZERO, all=.true.)
       call setval(Source_nph(n)        , ZERO, all=.true.)
       call setval(thermal(n)           , ZERO, all=.true.)
       call setval(s2star(n)            , ZERO, all=.true.)
       call setval(rho_omegadot2_hold(n), ZERO, all=.true.)
       
       if (dm.eq.3) then
          call multifab_build(w0_cart_vec(n)      , mla%la(n), dm, 1)
          call multifab_build(w0_force_cart_vec(n), mla%la(n), dm, 1)
          call setval(w0_cart_vec(n)      , ZERO, all=.true.)
          call setval(w0_force_cart_vec(n), ZERO, all=.true.)
       end if

       if (spherical.eq.1) then
          call multifab_build(div_coeff_3d(n), mla%la(nlevs), 1, 1)
          call setval(div_coeff_3d(n), ZERO, all=.true.)
       endif
    end do

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 1 -- define average expansion at time n+1/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< CALLING advance_timestep with dt =',dt 
       write(6,*) '<<< STEP  1 : make w0 >>> '
    end if
    
    if (init_mode) then
       call make_S_at_halftime(nlevs,Source_nph,Source_old,Source_new)
    else
       call extrap_to_halftime(nlevs,Source_nph,dSdt,Source_old,dt)
    endif
    
    call average(mla,Source_nph,Sbar,dx,1,1)
    
    call make_w0(nlevs,w0,w0_old,w0_force,Sbar(:,:,1),p0_old, &
                 s0_old(:,:,rho_comp),gam1,eta,dt,dtold,verbose)
    
    if (dm .eq. 3) then
       call make_w0_cart(nlevs,w0      ,w0_cart_vec      ,normal,dx) 
       call make_w0_cart(nlevs,w0_force,w0_force_cart_vec,normal,dx) 
    end if
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 2 -- construct the advective velocity
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  2 : create MAC velocities>>> '
    end if
    
    call advance_premac(nlevs,uold,sold,umac,uedge,utrans,gp,normal,w0,w0_cart_vec, &
                        s0_old,grav_cell_old,dx,dt,the_bc_tower%bc_tower_array,mla)
    
    call make_macrhs(nlevs,macrhs,Source_nph,gamma1_term,Sbar(:,:,1),div_coeff_old,dx)
    
    ! MAC projection !
    if (spherical .eq. 1) then
       call fill_3d_data_wrapper(nlevs,div_coeff_3d,div_coeff_old,dx)
       call macproject(mla,umac,macphi,sold,dx,the_bc_tower, &
                       verbose,mg_verbose,cg_verbose,press_comp, &
                       macrhs,div_coeff_3d=div_coeff_3d)
    else
       do n = 1, nlevs
          call cell_to_edge(n,div_coeff_old(n,:),div_coeff_edge(n,:))
       enddo
       call macproject(mla,umac,macphi,sold,dx,the_bc_tower, &
            verbose,mg_verbose,cg_verbose,press_comp, &
            macrhs,div_coeff_1d=div_coeff_old,div_coeff_half_1d=div_coeff_edge)
    end if
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 3 -- react the full state and then base state through dt/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  3 : react state     '
       write(6,*) '            : react  base >>> '
    end if
    
    call react_state(nlevs,mla,sold,s1,rho_omegadot1,rho_Hext,halfdt,dx, &
                     the_bc_tower%bc_tower_array,time)
    
    call average(mla,rho_omegadot1,rho_omegadotbar1,dx,1,nspec)
    call average(mla,rho_Hext,rho_Hextbar,dx,1,1)
    if (evolve_base_state) then
       call react_base(nlevs,p0_old,s0_old,rho_omegadotbar1,rho_Hextbar(:,:,1),halfdt, &
                       p0_1,s0_1,gam1)
    else
       p0_1 = p0_old
       s0_1 = s0_old
    end if

    do n=1,nlevs
       call make_grav_cell(n,grav_cell_new(n,:),s0_1(n,:,rho_comp))
       call make_div_coeff(n,div_coeff_new(n,:),s0_1(n,:,rho_comp),p0_1(n,:), &
                           gam1(n,:),grav_cell_new(n,:),anelastic_cutoff)
    enddo
    
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 4 -- advect the base state and full state through dt
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  4 : advect base        '
       write(6,*) '            : scalar_advance >>> '
    end if
    
    if (evolve_base_state) then
       call advect_base(nlevs,w0,Sbar,p0_1,p0_2,s0_1,s0_2,gam1,div_coeff_new,eta, &
                        dx(:,dm),dt,anelastic_cutoff)
    else
       p0_2 = p0_1
       s0_2 = s0_1
    end if
    
    if(use_thermal_diffusion) then
       call make_explicit_thermal(mla,dx,thermal,s1,p0_1,mg_verbose,cg_verbose, &
                                  the_bc_tower,temp_diffusion_formulation)
    else
       do n = 1,nlevs
          call setval(thermal(n),ZERO,all=.true.)
       end do
    endif
    
    ! thermal is the temperature forcing if we use the temperature godunov predictor
    ! so we add the reaction terms to thermal
    if(istep .le. 1) then
       call add_react_to_thermal(nlevs,thermal,rho_omegadot1,s1, &
                                 the_bc_tower%bc_tower_array,mla,dx)
    else
       call add_react_to_thermal(nlevs,thermal,rho_omegadot2,s1, &
                                 the_bc_tower%bc_tower_array,mla,dx)
       do n=1, nlevs
          call multifab_copy_c(rho_omegadot2_hold(n),1,rho_omegadot2(n),1,3,0)
       enddo
    endif
    
    call scalar_advance(nlevs,mla,1,uold,s1,s2,thermal,umac,w0,w0_cart_vec,eta, &
                        sedge,sflux,utrans,scal_force,normal,s0_1,s0_2, &
                        p0_1,p0_2,dx,dt,the_bc_tower%bc_tower_array,verbose)
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 4a (Option I) -- Add thermal conduction (only enthalpy terms)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (use_thermal_diffusion) then
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  4a: thermal conduct >>>'
       end if
       
       if(do_half_alg) then
          call thermal_conduct_half_alg(mla,dx,dt,s1,s2,p0_1,p0_2, &
                                        s0_1(:,:,temp_comp), s0_2(:,:,temp_comp), &
                                        mg_verbose,cg_verbose,the_bc_tower)
       else
          call thermal_conduct_full_alg(mla,dx,dt,s1,s1,s2,p0_1,p0_2, &
                                        s0_1(:,:,temp_comp),s0_2(:,:,temp_comp), &
                                        mg_verbose,cg_verbose,the_bc_tower)
          
          ! make a copy of s2star since these are needed to compute
          ! coefficients in the call to thermal_conduct_full_alg
          do n=1,nlevs
             call multifab_copy_c(s2star(n),1,s2(n),1,nscal,ng_cell)
          enddo
       endif
    endif
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 5 -- react the full state and then base state through dt/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  5 : react state     '
       write(6,*) '            : react  base >>> '
    end if
    
    call react_state(nlevs,mla,s2,snew,rho_omegadot2,rho_Hext,halfdt,dx, &
                     the_bc_tower%bc_tower_array,time)

    call average(mla,rho_omegadot2,rho_omegadotbar2,dx,1,nspec)
    call average(mla,rho_Hext,rho_Hextbar,dx,1,1)
    if (evolve_base_state) then
       call react_base(nlevs,p0_2,s0_2,rho_omegadotbar2,rho_Hextbar(:,:,1),halfdt, &
                       p0_new,s0_new,gam1)
    else
       p0_new = p0_2
       s0_new = s0_2
    end if

    do n=1,nlevs
       call make_grav_cell(n,grav_cell_new(n,:),s0_new(n,:,rho_comp))
       call make_div_coeff(n,div_coeff_new(n,:),s0_new(n,:,rho_comp),p0_new(n,:), &
                           gam1(n,:),grav_cell_new(n,:),anelastic_cutoff)
    enddo
    
    ! Define rho at half time !
    call make_at_halftime(nlevs,rhohalf,sold,snew,rho_comp,1,dx, &
                          the_bc_tower%bc_tower_array,mla)
    
    ! Define base state at half time for use in velocity advance!
    do n=1,nlevs
       do j=0,nr(n)-1
          s0_nph(n,j,:) = HALF * (s0_old(n,j,:) + s0_new(n,j,:))
       enddo
    enddo
    
    do n=1,nlevs
       call make_grav_cell(n,grav_cell_nph(n,:),s0_nph(n,:,rho_comp))
    enddo
    
    ! Define beta at half time !
    do n=1,nlevs
       do j=0,nr(n)-1
          div_coeff_nph(n,j) = HALF * (div_coeff_old(n,j) + div_coeff_new(n,j))
       enddo
    enddo
    
    if(.not. do_half_alg) then
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 6 -- define a new average expansion rate at n+1/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  6 : make new S and new w0 >>> '
       end if
       
       if(use_thermal_diffusion) then
          call make_explicit_thermal(mla,dx,thermal,snew,p0_new,mg_verbose,cg_verbose, &
                                     the_bc_tower,temp_diffusion_formulation)
       else
          do n = 1,nlevs
             call setval(thermal(n),ZERO)
          end do
       endif
       
       call make_S(nlevs,Source_new,gamma1_term,snew,rho_omegadot2,rho_Hext,thermal, &
                   s0_old(:,:,temp_comp),gam1,dx)
       
       call make_S_at_halftime(nlevs,Source_nph,Source_old,Source_new)
       
       do n = 1, nlevs
          call average(mla,Source_nph,Sbar,dx,1,1)
       end do
       
       call make_w0(nlevs,w0,w0_old,w0_force,Sbar(:,:,1),p0_new, &
                    s0_new(:,:,rho_comp),gam1,eta,dt,dtold,verbose)
       
       if (dm .eq. 3) then
          call make_w0_cart(nlevs,w0      ,w0_cart_vec      ,normal,dx) 
          call make_w0_cart(nlevs,w0_force,w0_force_cart_vec,normal,dx) 
       end if
       
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 7 -- redo the construction of the advective velocity using the current w0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  7 : create MAC velocities >>> '
       end if
       
       call advance_premac(nlevs,uold,sold,umac,uedge,utrans,gp,normal,w0, &
                           w0_cart_vec,s0_old,grav_cell_old,dx,dt, &
                           the_bc_tower%bc_tower_array,mla)
       
       call make_macrhs(nlevs,macrhs,Source_nph,gamma1_term,Sbar(:,:,1),div_coeff_nph,dx)
       
       ! MAC projection !
       if (spherical .eq. 1) then
          call fill_3d_data_wrapper(nlevs,div_coeff_3d,div_coeff_nph,dx)
          call macproject(mla,umac,macphi,rhohalf,dx,the_bc_tower, &
                          verbose,mg_verbose,cg_verbose,&
                          press_comp,macrhs,div_coeff_3d=div_coeff_3d)
       else
          do n = 1, nlevs
             call cell_to_edge(n,div_coeff_nph(n,:),div_coeff_edge(n,:))
          enddo
          call macproject(mla,umac,macphi,rhohalf,dx,the_bc_tower, &
                          verbose,mg_verbose,cg_verbose,&
                          press_comp,macrhs,div_coeff_1d=div_coeff_nph, &
                          div_coeff_half_1d=div_coeff_edge)
       end if
        
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 8 -- advect the base state and full state through dt
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  8 : advect base   '
          write(6,*) '            : scalar_advance >>>'
       end if
       if (evolve_base_state) then
          call advect_base(nlevs,w0,Sbar,p0_1,p0_2,s0_1,s0_2,gam1,div_coeff_nph,eta, &
                           dx(:,dm),dt,anelastic_cutoff)
       else
          p0_2 = p0_1
          s0_2 = s0_1
       end if
       
       if(use_thermal_diffusion) then
          call make_explicit_thermal(mla,dx,thermal,s1,p0_1,mg_verbose,cg_verbose, &
                                     the_bc_tower,temp_diffusion_formulation)
       else
          do n = 1,nlevs
             call setval(thermal(n),ZERO)
          end do
       endif
       
       ! thermal is the temperature forcing if we use the temperature godunov predictor
       ! so we add the reaction terms to thermal
       if(istep .le. 1) then
          call add_react_to_thermal(nlevs,thermal,rho_omegadot1,s1, &
                                    the_bc_tower%bc_tower_array,mla,dx)
       else
          call add_react_to_thermal(nlevs,thermal,rho_omegadot2_hold,s1, &
                                    the_bc_tower%bc_tower_array,mla,dx)
       endif
       
       call scalar_advance(nlevs,mla,2,uold,s1,s2,thermal,umac,w0,w0_cart_vec,eta, &
                           sedge,sflux,utrans,scal_force,normal,s0_1,s0_2, &
                           p0_1,p0_2,dx,dt,the_bc_tower%bc_tower_array,verbose)
       
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 8a (Option I) -- Add thermal conduction (only enthalpy terms)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (use_thermal_diffusion) then
          if (parallel_IOProcessor() .and. verbose .ge. 1) then
             write(6,*) '<<< STEP  8a: thermal conduct >>>'
          end if
          
          call thermal_conduct_full_alg(mla,dx,dt,s1,s2star,s2,p0_1,p0_2, &
                                        s0_1(:,:,temp_comp),s0_2(:,:,temp_comp), &
                                        mg_verbose,cg_verbose,the_bc_tower)
          
       endif
       
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 9 -- react the full state and then base state through dt/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  9 : react state '
          write(6,*) '            : react  base >>>'
       end if

       call react_state(nlevs,mla,s2,snew,rho_omegadot2,rho_Hext,halfdt,dx,&
                        the_bc_tower%bc_tower_array,time)

       call average(mla,rho_omegadot2,rho_omegadotbar2,dx,1,nspec)
       call average(mla,rho_Hext,rho_Hextbar,dx,1,1)
       if (evolve_base_state) then
          call react_base(nlevs,p0_2,s0_2,rho_omegadotbar2,rho_Hextbar(:,:,1),halfdt, &
                          p0_new,s0_new,gam1)
       else
          p0_new = p0_2
          s0_new = s0_2
       end if

       do n=1,nlevs
          call make_grav_cell(n,grav_cell_new(n,:),s0_new(n,:,rho_comp))
          call make_div_coeff(n,div_coeff_new(n,:),s0_new(n,:,rho_comp),p0_new(n,:), &
                              gam1(n,:),grav_cell_new(n,:),anelastic_cutoff)
       enddo
       
       ! endif corresponding to .not. do_half_alg
    endif
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 10 -- compute S^{n+1} for the final projection
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP 10 : make new S >>>'
    end if
    
    if(use_thermal_diffusion) then
       call make_explicit_thermal(mla,dx,thermal,snew,p0_new,mg_verbose,cg_verbose, &
                                  the_bc_tower,temp_diffusion_formulation)
    else
       do n = 1,nlevs
          call setval(thermal(n),ZERO)
       end do
    endif
    
    call make_S(nlevs,Source_new,gamma1_term,snew,rho_omegadot2,rho_Hext,thermal, &
                s0_new(:,:,temp_comp),gam1,dx)

    call average(mla,Source_new,Sbar,dx,1,1)
    
    ! define dSdt = (Source_new - Source_old) / dt
    do n = 1,nlevs
       call multifab_copy(dSdt(n),Source_new(n))
       call multifab_sub_sub(dSdt(n),Source_old(n))
       call multifab_div_div_s(dSdt(n),dt)
    end do
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 11 -- update the velocity
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP 11 : update and project new velocity >>>'
    end if
    
    ! Define rho at half time using the new rho from Step 8!
    call make_at_halftime(nlevs,rhohalf,sold,snew,rho_comp,1,dx, &
                          the_bc_tower%bc_tower_array,mla)
    
    call velocity_advance(nlevs,mla,uold,unew,sold,rhohalf,umac,uedge,utrans,gp, &
                          normal,w0,w0_cart_vec,w0_force,w0_force_cart_vec,s0_old,s0_nph, &
                          grav_cell_old,grav_cell_nph,dx,dt, &
                          the_bc_tower%bc_tower_array,sponge,do_sponge,verbose)
    
    ! Define beta at half time using the div_coeff_new from step 9!
    do n=1,nlevs
       do j=0,nr(n)-1
          div_coeff_nph(n,j) = HALF * (div_coeff_old(n,j) + div_coeff_new(n,j))
       end do
    enddo
       
    ! Project the new velocity field.
    if (init_mode) then
       proj_type = pressure_iters
       do n = 1, nlevs
          call multifab_copy(hgrhs_old(n),hgrhs(n))
       enddo
       call make_hgrhs(nlevs,hgrhs,Source_new,gamma1_term,Sbar(:,:,1),div_coeff_new,dx)
       do n = 1, nlevs
          call multifab_sub_sub(hgrhs(n),hgrhs_old(n))
          call multifab_div_div_s(hgrhs(n),dt)
       end do
    else
       proj_type = regular_timestep
       call make_hgrhs(nlevs,hgrhs,Source_new,gamma1_term,Sbar(:,:,1),div_coeff_new,dx)
    end if
    
    if (spherical .eq. 1) then
       call fill_3d_data_wrapper(nlevs,div_coeff_3d,div_coeff_nph,dx)
       eps_in = 1.d-12
       call hgproject(proj_type, mla, unew, uold, rhohalf, p, gp, dx, dt, &
                      the_bc_tower, verbose, mg_verbose, cg_verbose, press_comp, &
                      hgrhs, div_coeff_3d=div_coeff_3d, eps_in = eps_in)
    else
       call hgproject(proj_type, mla, unew, uold, rhohalf, p, gp, dx, dt, &
                      the_bc_tower, verbose, mg_verbose, cg_verbose, press_comp, &
                      hgrhs, div_coeff_1d=div_coeff_nph)
    end if
    
    ! If doing pressure iterations then put hgrhs_old into hgrhs to be returned to varden.
    if (init_mode) then
       do n = 1,nlevs
          call multifab_copy(hgrhs(n),hgrhs_old(n))
       end do
    end if
    
    do n = 1, nlevs
       call destroy(Source_nph(n))
       call destroy(macrhs(n))
       call destroy(macphi(n))
       call destroy(hgrhs_old(n))
       call destroy(thermal(n))
       call destroy(rhohalf(n))
       call destroy(s2star(n))
       call destroy(rho_omegadot2_hold(n))
       if (spherical .eq. 1) &
            call destroy(div_coeff_3d(n))
    end do
    deallocate(Source_nph)
    deallocate(macrhs)
    deallocate(macphi)
    deallocate(hgrhs_old)
    deallocate(thermal)
    deallocate(rhohalf)
    deallocate(s2star)
    deallocate(rho_omegadot2_hold)
    
    if (spherical .eq. 1) &
         deallocate(div_coeff_3d)
    
    if (dm .eq. 3) then
       do n = 1, nlevs
          call destroy(w0_cart_vec(n))
          call destroy(w0_force_cart_vec(n))
       end do
    end if
    
    deallocate(w0_cart_vec)
    deallocate(w0_force_cart_vec)
    
    deallocate(Sbar)
    deallocate(s0_nph)
    deallocate(div_coeff_nph)
    deallocate(div_coeff_edge)
    deallocate(grav_cell_nph)
    deallocate(grav_cell_new)
    
    deallocate(rho_omegadotbar1)
    deallocate(rho_omegadotbar2)
    deallocate(rho_Hextbar)
    
    deallocate(w0_old)
    deallocate(w0_force)
    
    deallocate(lo)
    deallocate(hi)
    
  end subroutine advance_timestep

end module advance_timestep_module

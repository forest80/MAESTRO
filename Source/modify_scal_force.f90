module modify_scal_force_module

  use multifab_module
  use ml_layout_module
  use define_bc_module

  implicit none

  private

  public :: modify_scal_force

contains

  subroutine modify_scal_force(which_step,nlevs,force,s,umac,base,base_edge,w0,eta,dx,base_cart, &
                               start_comp,num_comp,mla,the_bc_level)

    use bl_prof_module
    use bl_constants_module
    use geometry, only: spherical
    use variables, only: foextrap_comp
    use multifab_physbc_module
    use ml_restriction_module
    use multifab_fill_ghost_module

    ! When we write the scalar equation in perturbational and convective
    ! form, the terms other than s'_t + U.grad s' act as source terms.  Add
    ! them to the forces here.
    
    integer        , intent(in   ) :: which_step, nlevs
    type(multifab) , intent(inout) :: force(:)
    type(multifab) , intent(in   ) :: s(:)
    type(multifab) , intent(in   ) :: umac(:,:)
    real(kind=dp_t), intent(in   ) :: base(:,0:,:), base_edge(:,0:,:), w0(:,0:)
    real(kind=dp_t), intent(in   ) :: eta(:,0:,:)
    real(kind=dp_t), intent(in   ) :: dx(:,:)
    type(multifab) , intent(in   ) :: base_cart(:)
    type(ml_layout), intent(inout) :: mla
    type(bc_level) , intent(in   ) :: the_bc_level(:)
    
    ! local
    integer :: i,ng,dm,n
    integer :: comp,start_comp,num_comp
    integer :: lo(s(1)%dim),hi(s(1)%dim)
    integer :: domlo(s(1)%dim),domhi(s(1)%dim)    

    type(box) :: domain

    real(kind=dp_t), pointer :: fp(:,:,:,:)
    real(kind=dp_t), pointer :: sp(:,:,:,:)
    real(kind=dp_t), pointer :: ump(:,:,:,:)
    real(kind=dp_t), pointer :: vmp(:,:,:,:)
    real(kind=dp_t), pointer :: wmp(:,:,:,:)
    real(kind=dp_t), pointer :: bcp(:,:,:,:)

    type(bl_prof_timer), save :: bpt

    call build(bpt, "modify_scal_force")
    
    dm = s(1)%dim
    ng = s(1)%ng

    do n=1,nlevs

       domain = layout_get_pd(s(n)%la)
       domlo = lwb(domain)
       domhi = upb(domain)
       
       do i=1,force(n)%nboxes
          if ( multifab_remote(force(n),i) ) cycle
          fp => dataptr(force(n),i)
          sp => dataptr(s(n),i)
          ump => dataptr(umac(n,1),i)
          vmp => dataptr(umac(n,2),i)
          lo = lwb(get_box(s(n),i))
          hi = upb(get_box(s(n),i))
          select case (dm)
          case (2)
             do comp = start_comp, start_comp+num_comp-1
                call modify_scal_force_2d(which_step,fp(:,:,1,comp),sp(:,:,1,comp), lo, hi, &
                                          ng,ump(:,:,1,1),vmp(:,:,1,1), &
                                          base(n,:,comp),base_edge(n,:,comp), &
                                          w0(n,:),eta(n,:,comp),dx(n,:))
             end do
          case(3)
             wmp  => dataptr(umac(n,3), i)
             if (spherical .eq. 1) then
                bcp => dataptr(base_cart(n), i)
                do comp = start_comp, start_comp+num_comp-1
                   call modify_scal_force_3d_sphr(n,fp(:,:,:,comp),sp(:,:,:,comp), &
                                                  lo,hi,domlo,domhi,ng, &
                                                  ump(:,:,:,1),vmp(:,:,:,1), &
                                                  wmp(:,:,:,1),bcp(:,:,:,comp), &
                                                  w0(n,:),dx(n,:))
                end do
             else
                do comp = start_comp, start_comp+num_comp-1
                   call modify_scal_force_3d_cart(fp(:,:,:,comp),sp(:,:,:,comp), &
                                                  lo,hi,ng,ump(:,:,:,1), &
                                                  vmp(:,:,:,1),wmp(:,:,:,1), &
                                                  base(n,:,comp),base_edge(n,:,comp), &
                                                  w0(n,:),eta(n,:,comp),dx(n,:))
                end do
             end if
          end select
       end do
       
    enddo

    if (nlevs .eq. 1) then

       ! fill ghost cells for two adjacent grids at the same level
       ! this includes periodic domain boundary ghost cells
       call multifab_fill_boundary_c(force(nlevs),start_comp,num_comp)
       
       ! fill non-periodic domain boundary ghost cells
       do comp = start_comp, start_comp+num_comp-1
          call multifab_physbc(force(nlevs),comp,foextrap_comp,1,the_bc_level(nlevs))
       enddo

    else

       ! the loop over nlevs must count backwards to make sure the finer grids are done first
       do n=nlevs,2,-1

          ! set level n-1 data to be the average of the level n data covering it
          call ml_cc_restriction_c(force(n-1),start_comp,force(n),start_comp, &
                                   mla%mba%rr(n-1,:),num_comp)

          ! fill level n ghost cells using interpolation from level n-1 data
          ! note that multifab_fill_boundary and multifab_physbc are called for
          ! both levels n-1 and n
          do comp = start_comp, start_comp+num_comp-1
             call multifab_fill_ghost_cells(force(n),force(n-1), &
                                            force(n)%ng,mla%mba%rr(n-1,:), &
                                            the_bc_level(n-1),the_bc_level(n), &
                                            comp,foextrap_comp,1)
          enddo

       enddo

    end if

    call destroy(bpt)
    
  end subroutine modify_scal_force
  
  subroutine modify_scal_force_2d(which_step,force,s,lo,hi,ng,umac,vmac,base,base_edge,w0,eta,dx)

    integer        , intent(in   ) :: which_step,lo(:),hi(:),ng
    real(kind=dp_t), intent(  out) :: force(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) ::     s(lo(1)-ng:,lo(2)-ng:)
    real(kind=dp_t), intent(in   ) ::  umac(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) ::  vmac(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) ::  base(0:), base_edge(0:)
    real(kind=dp_t), intent(in   ) ::    w0(0:)
    real(kind=dp_t), intent(in   ) ::  eta(0:)
    real(kind=dp_t), intent(in   ) :: dx(:)
    
    integer :: i,j
    real(kind=dp_t) :: divu,divbaseu
    
    do j = lo(2),hi(2)
       do i = lo(1),hi(1)
          divu =  (umac(i+1,j) - umac(i,j)) / dx(1) &
               +( (vmac(i,j+1) + w0(j+1)) &
                 -(vmac(i,j)   + w0(j)  ) ) / dx(2)
          divbaseu = base(j)*(umac(i+1,j) - umac(i,j))/dx(1) &
               +(vmac(i,j+1) * base_edge(j+1) &
               - vmac(i,j  ) * base_edge(j  ) )/ dx(2)
          
          force(i,j) = force(i,j) - (s(i,j)-base(j))*divu - divbaseu 
       end do
    end do
          
    if (which_step .eq. 2) then
       do j = lo(2),hi(2)
       do i = lo(1),hi(1)
          force(i,j) = force(i,j) + (eta(j+1) - eta(j))/dx(2)
       end do
       end do
    end if
    
  end subroutine modify_scal_force_2d
  
  subroutine modify_scal_force_3d_cart(force,s,lo,hi,ng,umac,vmac,wmac,base,base_edge,w0,eta,dx)

    integer        , intent(in   ) :: lo(:),hi(:),ng
    real(kind=dp_t), intent(  out) :: force(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: s(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:)
    real(kind=dp_t), intent(in   ) ::  umac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) ::  vmac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) ::  wmac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: base(0:), base_edge(0:)
    real(kind=dp_t), intent(in   ) ::   w0(0:)
    real(kind=dp_t), intent(in   ) ::  eta(0:)
    real(kind=dp_t), intent(in   ) :: dx(:)
    
    integer :: i,j,k
    real(kind=dp_t) :: divu,divbaseu
    
    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)
             divu = (umac(i+1,j,k) - umac(i,j,k)) / dx(1) &
                   +(vmac(i,j+1,k) - vmac(i,j,k)) / dx(2) &
                   +(wmac(i,j,k+1) - wmac(i,j,k)) / dx(3)
             divbaseu = base(k)*( (umac(i+1,j,k) - umac(i,j,k))/dx(1) &
                                 +(vmac(i,j+1,k) - vmac(i,j,k))/dx(2) ) &
                                 +(wmac(i,j,k+1) * base_edge(k+1) &
                                 - wmac(i,j,k  ) * base_edge(k  ))/ dx(3)
             divu = divu + (w0(k+1)-w0(k))/dx(3)
             force(i,j,k) = force(i,j,k) - (s(i,j,k)-base(k))*divu - divbaseu + &
                  (eta(k+1) - eta(k))/dx(3)
          end do
       end do
    end do
    
  end subroutine modify_scal_force_3d_cart
  
  subroutine modify_scal_force_3d_sphr(n,force,s,lo,hi,domlo,domhi,ng, &
                                       umac,vmac,wmac,base_cart,w0,dx)

    use geometry, only: nr, base_loedge_loc, dr, base_cc_loc
    use fill_3d_module
    use bl_constants_module
    
    integer        , intent(in   ) :: n,lo(:),hi(:),domlo(:),domhi(:),ng
    real(kind=dp_t), intent(  out) :: force(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)
    real(kind=dp_t), intent(in   ) ::     s(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:)
    real(kind=dp_t), intent(in   ) ::  umac(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)
    real(kind=dp_t), intent(in   ) ::  vmac(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)
    real(kind=dp_t), intent(in   ) ::  wmac(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)
    
    real(kind=dp_t), intent(in   ) :: base_cart(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: w0(0:)
    real(kind=dp_t), intent(in   ) :: dx(:)
    
    ! Local variables
    integer :: i,j,k,r
    real(kind=dp_t) :: divumac,divbaseu
    real(kind=dp_t) :: base_xlo,base_xhi
    real(kind=dp_t) :: base_ylo,base_yhi
    real(kind=dp_t) :: base_zlo,base_zhi
    
    real(kind=dp_t), allocatable :: divu(:),divu_cart(:,:,:)
    
    allocate(divu(0:nr(n)-1))
    allocate(divu_cart(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3)))
    
    do r = 0,nr(n)-1
       divu(r) = (base_loedge_loc(n,r+1)**2 &
            * w0(r+1)- base_loedge_loc(n,r)**2 * w0(r))/(dr(n)*base_cc_loc(n,r)**2)
    end do
    call fill_3d_data(n,divu_cart,divu,lo,hi,dx,0)
    
    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)
             
             divumac = (umac(i+1,j,k) - umac(i,j,k)) / dx(1) &
                  +(vmac(i,j+1,k) - vmac(i,j,k)) / dx(2) &
                  +(wmac(i,j,k+1) - wmac(i,j,k)) / dx(3)
             
             if (i.lt.domhi(1)) then
                base_xhi = HALF * (base_cart(i,j,k) + base_cart(i+1,j,k))
             else
                base_xhi = base_cart(i,j,k)
             end if
             if (i.gt.domlo(1)) then
                base_xlo = HALF * (base_cart(i,j,k) + base_cart(i-1,j,k))
             else
                base_xlo = base_cart(i,j,k)
             end if
             if (j.lt.domhi(2)) then
                base_yhi = HALF * (base_cart(i,j,k) + base_cart(i,j+1,k))
             else
                base_yhi = base_cart(i,j,k)
             end if
             if (j.gt.domlo(2)) then
                base_ylo = HALF * (base_cart(i,j,k) + base_cart(i,j-1,k))
             else
                base_ylo = base_cart(i,j,k)
             end if
             if (k.lt.domhi(3)) then
                base_zhi = HALF * (base_cart(i,j,k) + base_cart(i,j,k+1))
             else
                base_zhi = base_cart(i,j,k)
             end if
             if (k.gt.domlo(3)) then
                base_zlo = HALF * (base_cart(i,j,k) + base_cart(i,j,k-1))
             else
                base_zlo = base_cart(i,j,k)
             end if
             
             divbaseu =  (umac(i+1,j,k) * base_xhi &
                        - umac(i  ,j,k) * base_xlo)/ dx(1) &
                        +(vmac(i,j+1,k) * base_yhi &
                         -vmac(i,j  ,k) * base_ylo)/ dx(2) &
                        +(wmac(i,j,k+1) * base_zhi &
                         -wmac(i,j,k  ) * base_zlo)/ dx(3)
             
             force(i,j,k) = force(i,j,k) - divbaseu &
                  -(s(i,j,k)-base_cart(i,j,k))*(divumac+divu_cart(i,j,k)) 
          end do
       end do
    end do
    
    deallocate(divu,divu_cart)
    
  end subroutine modify_scal_force_3d_sphr
  
end module modify_scal_force_module
 

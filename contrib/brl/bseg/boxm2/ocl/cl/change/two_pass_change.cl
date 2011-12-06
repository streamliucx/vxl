#if NVIDIA
 #pragma OPENCL EXTENSION cl_khr_gl_sharing : enable
#endif


#ifdef CHANGE_SEGLEN
//PASS ONE - this caches seglen and mean observations in each cell
typedef struct
{
  __constant  RenderSceneInfo* linfo;
  __global    float*      alpha;      //model alpha
  __global    int*        seg_len;    //seglen aux buffer
  __global    int*        mean_obs;   //mean obs aux buffer
              float       obs;        //input image obs
              
              float*      ray_len;     //output debugger
} AuxArgs;

//forward declare cast ray (so you can use it)
void cast_ray(int,int,float,float,float,float,float,float,__constant RenderSceneInfo*,
              __global int4*,local uchar16*,constant uchar *,local uchar *,float*,AuxArgs);
__kernel
void
change_seg_len(__constant  RenderSceneInfo    * linfo,
               __global    int4               * tree_array,       // tree structure for each block
               __global    float              * alpha_array,      // alpha for each block
               __global    int                * aux_seg_len,      // aux data array (four aux arrays strung together)
               __global    int                * aux_mean_obs,     // aux data array (four aux arrays strung together)
               __constant  uchar              * bit_lookup,       // used to get data_index
               __global    float4             * ray_origins,
               __global    float4             * ray_directions,
               __global    uint4              * imgdims,          // dimensions of the input image
               __global    float              * in_image,         // the input image
               __global    float              * output,
               __local     uchar16            * local_tree,       // cache current tree into local memory
               __local     uchar              * cumsum )          // cumulative sum for calculating data pointer
{
  //get local id (0-63 for an 8x8) of this patch
  uchar llid = (uchar)(get_local_id(0) + get_local_size(0)*get_local_id(1));

  //----------------------------------------------------------------------------
  // get image coordinates and camera,
  // check for validity before proceeding
  //----------------------------------------------------------------------------
  int i=0,j=0;
  i=get_global_id(0);
  j=get_global_id(1);
  int imIndex = j*get_global_size(0) + i;

  //grab input image value (also holds vis)
  float ray_len = output[imIndex]; 
  float obs = in_image[imIndex];
  float vis = 1.0f;  //no visibility in this pass
  barrier(CLK_LOCAL_MEM_FENCE);

  // cases #of threads will be more than the pixels.
  if (i>=(*imgdims).z || j>=(*imgdims).w || i<(*imgdims).x || j<(*imgdims).y || obs < 0.0f)
    return;

  //----------------------------------------------------------------------------
  // we know i,j map to a point on the image,
  // BEGIN RAY TRACE
  //----------------------------------------------------------------------------
  float4 ray_o = ray_origins[ imIndex ];
  float4 ray_d = ray_directions[ imIndex ];
  float ray_ox, ray_oy, ray_oz, ray_dx, ray_dy, ray_dz;
  calc_scene_ray_generic_cam(linfo, ray_o, ray_d, &ray_ox, &ray_oy, &ray_oz, &ray_dx, &ray_dy, &ray_dz);

  //----------------------------------------------------------------------------
  // we know i,j map to a point on the image, have calculated ray
  // BEGIN RAY TRACE
  //----------------------------------------------------------------------------
  AuxArgs aux_args;
  aux_args.linfo    = linfo;
  aux_args.alpha    = alpha_array;
  aux_args.obs      = obs;
  aux_args.seg_len  = aux_seg_len;
  aux_args.mean_obs = aux_mean_obs;
  aux_args.ray_len  = &ray_len; 
  cast_ray( i, j,
            ray_ox, ray_oy, ray_oz,
            ray_dx, ray_dy, ray_dz,
            linfo, tree_array,                                  //scene info
            local_tree, bit_lookup, cumsum, &vis, aux_args);    //utility info
}

//seg_len step cell functor. does two atomic sums
void step_cell_seglen(AuxArgs aux_args, int data_ptr, uchar llid, float d)
{
  int seg_int = convert_int_rte(d * SEGLEN_FACTOR);
  atom_add(&aux_args.seg_len[data_ptr], seg_int);
  int cum_obs = convert_int_rte(d * aux_args.obs * SEGLEN_FACTOR);
  atom_add(&aux_args.mean_obs[data_ptr], cum_obs);
}
#endif

#ifdef CHANGE
//need to define a struct of type AuxArgs with auxiliary arguments
// to supplement cast ray args
typedef struct
{
  __constant  RenderSceneInfo* linfo;
  
  //cell data
  __global float*       alpha;
  __global MOG_TYPE *   mog;
  __global int*         seg_len;
  __global int*         mean_obs;
  
  //ray data
           float        intensity;
           float        intensity_exp;
           float*       change;
           float*       change_exp;
           float*       ray_vis;
} AuxArgs;

//forward declare cast ray (so you can use it)
void cast_ray(int,int,float,float,float,float,float,float,constant RenderSceneInfo*,
              global int4*,local uchar16*,constant uchar*,local uchar*, float*, AuxArgs);

//------------------------------------------------------------------------------
// 1x1 change detection (simple, single ray independent CD). 
//------------------------------------------------------------------------------
__kernel
void
two_pass_change_kernel    ( __constant  RenderSceneInfo    * linfo,
                            __global    int4               * tree_array,
                            __global    float              * alpha_array,
                            __global    MOG_TYPE           * mixture_array,
                            __global    int                * aux_seg_len,
                            __global    int                * aux_mean_obs,
                            __global    float4             * ray_origins,
                            __global    float4             * ray_directions,
                            __global    float              * in_image,      // input image and store vis_inf and pre_inf
                            __global    float              * exp_image,      // input image and store vis_inf and pre_inf
                            __global    float              * change_image,      // input image and store vis_inf and pre_inf
                            __global    float              * change_exp_image,       //input image
                            __global    uint4              * exp_image_dims,
                            __global    float              * output,
                            __constant  uchar              * bit_lookup,
                            __global    float              * vis_image,
                            __local     uchar16            * local_tree,
                            __local     uchar              * cumsum,        //cumulative sum helper for data pointer
                            __local     int                * imIndex)
{
  //get local id (0-63 for an 8x8) of this patch + image coordinates and camera
  uchar llid = (uchar)(get_local_id(0) + get_local_size(0)*get_local_id(1));
  int i=0,j=0;
  i=get_global_id(0);
  j=get_global_id(1);
  imIndex[llid] = j*get_global_size(0)+i;

  // check to see if the thread corresponds to an actual pixel as in some
  // cases #of threads will be more than the pixels.
  if (i>=(*exp_image_dims).z || j>=(*exp_image_dims).w) {
    return;
  }

  //change, change_exp
  float change          = change_image[imIndex[llid]];
  float change_exp      = change_exp_image[imIndex[llid]];
  float intensity_exp   = exp_image[imIndex[llid]];
  float intensity       = in_image[imIndex[llid]];
  float vis             = vis_image[imIndex[llid]];

  //find neighbor pixel
  int currI = i; 
  int currJ = j; 
    
  //calc scene ray
  float4 ray_o = ray_origins[ imIndex[llid] ];
  float4 ray_d = ray_directions[ imIndex[llid] ];
  float ray_ox, ray_oy, ray_oz, ray_dx, ray_dy, ray_dz;
  calc_scene_ray_generic_cam(linfo, ray_o, ray_d, &ray_ox, &ray_oy, &ray_oz, &ray_dx, &ray_dy, &ray_dz);

  AuxArgs aux_args;
  aux_args.linfo        = linfo;
  aux_args.alpha        = alpha_array;
  aux_args.mog          = mixture_array;
  aux_args.seg_len      = aux_seg_len; 
  aux_args.mean_obs     = aux_mean_obs; 
  
  aux_args.ray_vis      = &vis; 
  aux_args.intensity    = intensity;
  aux_args.intensity_exp= intensity_exp;
  aux_args.change       = &change;
  aux_args.change_exp   = &change_exp;
  cast_ray( currI, currJ,
            ray_ox, ray_oy, ray_oz,
            ray_dx, ray_dy, ray_dz,

            //scene info
            linfo, tree_array,

            //utility info
            local_tree, bit_lookup, cumsum, &vis,

            //RENDER SPECIFIC ARGS
            aux_args);
            
  //expected image gets rendered
  change_image[imIndex[llid]]     = change;  //expected_int;
  change_exp_image[imIndex[llid]] = change_exp; //expected_int;
  vis_image[imIndex[llid]]        = vis;
}


// Change detection step cell functor
void step_cell_change(AuxArgs aux_args, int data_ptr, uchar llid, float d)
{
  //d-normalize the ray seg len
  d *= aux_args.linfo->block_len;
  
  //get cell cumulative length and make sure it isn't 0
  int len_int = aux_args.seg_len[data_ptr];
  float cum_len  = convert_float(len_int)/SEGLEN_FACTOR;
        
  int obs_int = aux_args.mean_obs[data_ptr];
  float mean_obs = convert_float(obs_int) / convert_float(len_int);

  //uchar8 uchar_data = cell_data[data_ptr];
  CONVERT_FUNC(uchar_data, aux_args.mog[data_ptr]);
  float8 data = convert_float8(uchar_data)/NORM;

  //choose value based on cell depth
  float prob_den=gauss_3_mixture_prob_density(mean_obs,
                                              data.s0,data.s1,data.s2,
                                              data.s3,data.s4,data.s5,
                                              data.s6,data.s7,1-data.s2-data.s5);

  //calculate prob density of expected image
  float alpha = aux_args.alpha[data_ptr];
  float prob  = 1.0f-exp(-alpha*d);
  float omega = (*aux_args.ray_vis)*prob;
  (*aux_args.ray_vis) *= (1.0f-prob);
  (*aux_args.change) += prob_den*omega;
  float e_prob_den=gauss_3_mixture_prob_density(aux_args.intensity_exp,
                                                data.s0,data.s1,data.s2,
                                                data.s3,data.s4,data.s5,
                                                data.s6,data.s7,1-data.s2-data.s5);
  (*aux_args.change_exp) += e_prob_den*omega;
}





//------------------------------------------------------------------------------
// NxN change detection (simple, single ray independent CD). 
//------------------------------------------------------------------------------
/*
__kernel
void
nxn_change_detection( __constant  RenderSceneInfo    * linfo,
                      __global    int4               * tree_array,
                      __global    float              * alpha_array,
                      __global    MOG_TYPE           * mixture_array,
                      __global    int                * offset_i,            //nxn offset (can be negative
                      __global    int                * offset_j,            //nxn offset (can be negative
                      __global    float16            * camera,              
                      __global    float4              * in_image,            // input image 
                      __global    float              * exp_image,           // expected image
                      __global    float              * change_image,        // change image
                      __global    float              * change_exp_image,    // change exp image
                      __global    float              * p1_prob_change_image, // first pass change image
                      __global    uint4              * exp_image_dims,
                      __global    float              * output,
                      __constant  uchar              * bit_lookup,
                      __global    float              * vis_image,
                      __local     uchar16            * local_tree,
                      __local     uchar              * cumsum,        
                      __local     int                * imIndex)
{
  //----------------------------------------------------------------------------
  //get local id (0-63 for an 8x8) of this patch + image coordinates and camera
  // check for validity before proceeding
  //----------------------------------------------------------------------------
  uchar llid = (uchar)(get_local_id(0) + get_local_size(0)*get_local_id(1));
  int i=0,j=0;
  i=get_global_id(0);
  j=get_global_id(1);
  imIndex[llid] = j*get_global_size(0)+i;

  // check to see if the thread corresponds to an actual pixel as in some
  // cases #of threads will be more than the pixels.
  if (i>=(*exp_image_dims).z || j>=(*exp_image_dims).w) {
    return;
  }

  //Second pass, do 3 loops on those who's change thresholds are hight enough
  float prob_change = p1_prob_change_image[imIndex[llid]]; 
  if( prob_change > 0.1f ) 
  {
    //calc neighbor pixel (grab intensity/vis from here)
    int currI = i + *offset_i; 
    int currJ = j + *offset_j; 
    if (currI>=(*exp_image_dims).z || currJ>=(*exp_image_dims).w) 
      return;
    int nIdx = currJ*get_global_size(0)+currI;
    
    //calc scene ray
    float ray_ox, ray_oy, ray_oz, ray_dx, ray_dy, ray_dz;
    calc_scene_ray(linfo, camera, currI, currJ, &ray_ox, &ray_oy, &ray_oz, &ray_dx, &ray_dy, &ray_dz);
  
    //set p change, change_exp, intensity and vis for this neighbor pixel
    float change          = change_image    [imIndex[llid]];
    float change_exp      = change_exp_image[imIndex[llid]];
    float vis             = vis_image       [imIndex[llid]];
   
    //intensity's belong to neighbor
    float intensity_exp   = exp_image[imIndex[llid]];
    float4 intensity       = in_image [imIndex[llid]];
    
    //setup aux args for step cell function
    AuxArgs aux_args;
    aux_args.alpha        = alpha_array;
    aux_args.mog          = mixture_array;
    aux_args.intensity    = intensity;
    aux_args.intensity_exp= intensity_exp;
    aux_args.change       = &change;
    aux_args.change_exp   = &change_exp;

    //cast neighbor ray
    cast_ray( i, j,
              ray_ox, ray_oy, ray_oz,
              ray_dx, ray_dy, ray_dz,

              //scene info
              linfo, tree_array,

              //utility info
              local_tree, bit_lookup, cumsum, &vis,

              //RENDER SPECIFIC ARGS
              aux_args);
    
    //expected image gets rendered
    change_image    [imIndex[llid]] = change;  //expected_int;
    change_exp_image[imIndex[llid]] = change_exp; //expected_int;
    vis_image       [imIndex[llid]] = vis;
  }
}
*/

#endif
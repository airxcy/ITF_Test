#include "itf/trackers/trackers.h"
#include "itf/trackers/gpucommon.hpp"
#include "itf/trackers/utils.h"
#include "thrust/sort.h"
#include "itf/trackers/fbcuda/SmallSort.cuh"
#include <iostream>
#include <stdio.h>
using namespace cv;
using namespace cv::gpu;
__device__ int d_framewidth[1],d_frameheight[1];

void setHW(int w,int h)
{
    cudaMemcpyToSymbol(d_framewidth,&w,sizeof(int));
    cudaMemcpyToSymbol(d_frameheight,&h,sizeof(int));
}

__global__ void applyPersToMask(unsigned char* d_mask,float* d_curvec,float* d_persMap)
{
    int pidx=blockIdx.x;
    float px=d_curvec[pidx*2],py=d_curvec[pidx*2+1];
    int blocksize = blockDim.x;
    int w=d_framewidth[0],h=d_frameheight[0];
    int localx = threadIdx.x,localy=threadIdx.y;
    int pxint = px+0.5,pyint = py+0.5;
    float persval =d_persMap[pyint*w+pxint];
    float range=Pers2Range(persval);
    int offset=range+0.5;
    int yoffset = localy-blocksize/2;
    int xoffset = localx-blocksize/2;
    if(abs(yoffset)<range&&abs(xoffset)<range)
    {
        int globalx=xoffset+pxint,globaly=yoffset+pyint;
        d_mask[globaly*d_framewidth[0]+globalx]=0;
    }
}

__global__ void applyPointPersMask(unsigned char* d_mask,FeatPts* cur_ptr,int* lenVec,float* d_persMap)
{
    int pidx=blockIdx.x;
    int len=lenVec[pidx];
    if(len>0)
    {
        float px=cur_ptr[pidx].x,py=cur_ptr[pidx].y;
        int blocksize = blockDim.x;
        int w=d_framewidth[0],h=d_frameheight[0];
        int localx = threadIdx.x,localy=threadIdx.y;
        int pxint = px+0.5,pyint = py+0.5;
        float persval =d_persMap[pyint*w+pxint];
        float range=Pers2Range(persval);
        int offset=range+0.5;
        int yoffset = localy-blocksize/2;
        int xoffset = localx-blocksize/2;
        if(abs(yoffset)<range&&abs(xoffset)<range)
        {
            int globalx=xoffset+pxint,globaly=yoffset+pyint;
            d_mask[globaly*w+globalx]=0;
        }
    }
}

__global__ void applySegMask(unsigned char* d_mask,unsigned char* d_segmask,unsigned char* d_segNeg)
{
    int offset=blockIdx.x*blockDim.x+threadIdx.x;
    int w=d_framewidth[0],h=d_frameheight[0];
    int totallen =w*h;
    int y=offset/w;
    int x=offset%w;
    if(offset<totallen&&!d_segNeg[offset]&&!d_segmask[offset])
    {
        d_mask[offset]=0;
    }
}

__global__ void renderFrame(unsigned char* d_renderMask,unsigned char* d_frameptr,int totallen)
{
    int offset=blockIdx.x*blockDim.x+threadIdx.x;
    int maskval = d_renderMask[offset];
    if(offset<totallen&&maskval)
    {
        d_frameptr[offset*3]*=0.5;
        d_frameptr[offset*3+1]*=0.5;
        d_frameptr[offset*3+2]*=0.5;
    }
}

__global__ void renderGroup(unsigned char* d_renderMask,FeatPts* cur_ptr,unsigned char* d_clrvec,float* d_persMap,int* d_neighbor)
{
    int pidx=blockIdx.x;
    int px=cur_ptr[pidx].x+0.5,py=cur_ptr[pidx].y+0.5;
    int blocksize = blockDim.x;
    int w=d_framewidth[0],h=d_frameheight[0];
    float persval =d_persMap[py*w+px];
    float range=Pers2Range(persval);
    int centerOffset=blocksize/2;
    int xoffset = threadIdx.x-centerOffset;
    float alpha = 0.5;
    for(int i=0;i<blocksize;i++)
    {
        int yoffset = i-centerOffset;
        if(abs(yoffset)<range&&abs(xoffset)<range)
        {
            int globalx=xoffset+px,globaly=yoffset+py;
            int offset = globaly*w+globalx;
            d_renderMask[offset*3]=150;
            d_renderMask[offset*3+1]=150;
            d_renderMask[offset*3+2]=150;
        }
    }
}


__global__ void searchNeighbor(TracksInfo trkinfo,
                               int* d_neighbor,float* d_cosine,float* d_velo,float* d_distmat,
                               float * d_persMap, int nFeatures)
{
    int c = threadIdx.x, r = blockIdx.x;
    int clen = trkinfo.lenVec[c],rlen = trkinfo.lenVec[r];
    FeatPts* cur_ptr=trkinfo.curTrkptr;
    if(clen>minTrkLen&&rlen>minTrkLen&&r<c)
    {
//        int offset = (tailidx+bufflen-minTrkLen)%bufflen;
//        FeatPts* pre_ptr=data_ptr+NQue*offset;
//        FeatPts* pre_ptr=trkinfo.preTrkptr;//trkinfo.getVec_(trkinfo.trkDataPtr,minTrkLen-1);
//        float cx0=pre_ptr[c].x,cy0=pre_ptr[c].y;
//        float rx0=pre_ptr[r].x,ry0=pre_ptr[r].y;
        float cx1=cur_ptr[c].x,cy1=cur_ptr[c].y;
        float rx1=cur_ptr[r].x,ry1=cur_ptr[r].y;
        float dx = abs(rx1 - cx1), dy = abs(ry1 - cy1);
        float dist = sqrt(dx*dx+dy*dy);
        int  ymid = (ry1 + cy1) / 2.0+0.5,xmid = (rx1 + cx1) / 2.0+0.5;
        float persval=0;
        int ymin=min(ry1,cy1),xmin=min(rx1,cx1);
        persval =d_persMap[ymin*d_framewidth[0]+xmin];
        float hrange=persval,wrange=persval;
        if(hrange<2)hrange=2;
        if(wrange<2)wrange=2;
        float distdecay=0.05,cosdecay=0.1,velodecay=0.05;
        /*
        float vx0 = rx1 - rx0, vx1 = cx1 - cx0, vy0 = ry1 - ry0, vy1 = cy1 - cy0;
        float norm0 = sqrt(vx0*vx0 + vy0*vy0), norm1 = sqrt(vx1*vx1 + vy1*vy1);
        float veloCo = abs(norm0-norm1)/(norm0+norm1);
        float cosine = (vx0*vx1 + vy0*vy1) / norm0 / norm1;
        */
        float vrx = trkinfo.curVeloPtr[r].x, vry = trkinfo.curVeloPtr[r].y
                , vcx = trkinfo.curVeloPtr[c].x, vcy = trkinfo.curVeloPtr[c].y;
        float normr=trkinfo.curSpdPtr[r],normc=trkinfo.curSpdPtr[c];
        float veloCo = abs(normr-normc)/(normr+normc);
        float cosine = (vrx*vcx + vry*vcy) / normr / normc;
        dist = wrange*1.5/(dist+0.01);
        dist=2*dist/(1+abs(dist))-1;
        //dist=-((dist > wrange) - (dist < wrange));
        d_distmat[r*nFeatures+c]=dist+d_distmat[r*nFeatures+c]*(1-distdecay);
        d_distmat[c*nFeatures+r]=dist+d_distmat[c*nFeatures+r]*(1-distdecay);
        d_cosine[r*nFeatures+c]=cosine+d_cosine[r*nFeatures+c]*(1-cosdecay);
        d_cosine[c*nFeatures+r]=cosine+d_cosine[c*nFeatures+r]*(1-cosdecay);
        d_velo[r*nFeatures+c]=veloCo+d_velo[r*nFeatures+c]*(1-velodecay);
        d_velo[c*nFeatures+r]=veloCo+d_velo[c*nFeatures+r]*(1-velodecay);
        if(d_distmat[r*nFeatures+c]>5&&d_cosine[r*nFeatures+c]>1)//&&d_velo[r*nFeatures+c]<(14*velodecay)*0.9)
        {
            d_neighbor[r*nFeatures+c]+=1;
            d_neighbor[c*nFeatures+r]+=1;
        }
        else
        {
            d_neighbor[r*nFeatures+c]/=2.0;
            d_neighbor[c*nFeatures+r]/=2.0;
        }

    }
}

__global__ void clearLostStats(int* lenVec,int* d_neighbor,float* d_cosine,float* d_velo,float* d_distmat,int nFeatures)
{
    int c=threadIdx.x,r=blockIdx.x;
    if(r<nFeatures,c<nFeatures)
    {
        bool flag1=(lenVec[c]>0),flag2=(lenVec[r]>0);
        bool flag=flag1&&flag2;
        if(!flag)
        {

            d_neighbor[r*nFeatures+c]=0;
            d_neighbor[c*nFeatures+r]=0;
            d_cosine[r*nFeatures+c]=0;
            d_cosine[c*nFeatures+r]=0;
            d_velo[r*nFeatures+c]=0;
            d_velo[c*nFeatures+r]=0;
            d_distmat[r*nFeatures+c]=0;
            d_distmat[c*nFeatures+r]=0;
        }
    }
}
__global__ void filterTracks(TracksInfo trkinfo,uchar* status,float2* update_ptr,float* d_persMap)
{
    int idx=threadIdx.x;
    int len = trkinfo.lenVec[idx];
    bool flag = status[idx];
    float x=update_ptr[idx].x,y=update_ptr[idx].y;
    int frame_width=d_framewidth[0],frame_heigh=d_frameheight[0];
    trkinfo.nextTrkptr[idx].x=x;
    trkinfo.nextTrkptr[idx].y=y;
    float curx=trkinfo.curTrkptr[idx].x,cury=trkinfo.curTrkptr[idx].y;
    float dx = x-curx,dy = y-cury;
    float dist = sqrt(dx*dx+dy*dy);
    float cumDist=dist+trkinfo.curDistPtr[idx];
    trkinfo.nextDistPtr[idx]=cumDist;
    if(flag&&len>0)
    {

        int xb=x+0.5,yb=y+0.5;
        float persval=d_persMap[yb*frame_width+xb];
//        int prex=trkinfo.curTrkptr[idx].x+0.5, prey=trkinfo.curTrkptr[idx].y+0.5;
//        int trkdist=abs(prex-xb)+abs(prey-yb);
        float trkdist=abs(dx)+abs(dy);
        if(trkdist>persval)
        {
            flag=false;
        }
        //printf("%d,%.2f,%d|",trkdist,persval,flag);
        int Movelen=150/sqrt(persval);
        //Movelen is the main factor wrt perspective
//        printf("%d\n",Movelen);
        if(flag&&Movelen<len)
        {
//            int offset = (tailidx+bufflen-Movelen)%bufflen;
//            FeatPts* dataptr = next_ptr-tailidx*NQue;
//            FeatPts* aptr = dataptr+offset*NQue;
//            float xa=aptr[idx].x,ya=aptr[idx].y;
            FeatPts* ptr = trkinfo.getPtr_(trkinfo.trkDataPtr,idx,Movelen);
            float xa=ptr->x,ya=ptr->y;
            float displc=sqrt((x-xa)*(x-xa) + (y-ya)*(y-ya));
            float curveDist=cumDist-*(trkinfo.getPtr_(trkinfo.distDataPtr,idx,Movelen));
            //if(persval*0.1>displc)
            if(curveDist<3&&displc<3)
            {
                flag=false;
            }
        }
    }
    int newlen =flag*(len+(len<trkinfo.buffLen));
    trkinfo.lenVec[idx]=newlen;
    if(newlen>minTrkLen)
    {
        FeatPts* pre_ptr=trkinfo.preTrkptr;
        float prex=pre_ptr[idx].x,prey=pre_ptr[idx].y;
        float vx = (x-prex)/minTrkLen,vy = (y-prey)/minTrkLen;
        float spd = sqrt(vx*vx+vy*vy);
        trkinfo.nextSpdPtr[idx]=spd;
        trkinfo.nextVeloPtr[idx].x=vx,trkinfo.nextVeloPtr[idx].y=vy;
    }
}

__global__ void  addNewPts(FeatPts* cur_ptr,int* lenVec,float2* new_ptr,float2* nextPtrs)
{
    int idx=threadIdx.x;
    int dim=blockDim.x;
    __shared__ int counter[1];
    counter[0]=0;
    __syncthreads();

    if(lenVec[idx]<=0)
    {
        int posidx = atomicAdd(counter,1);
        //printf("(%d,%.2f,%.2f)",posidx,new_ptr[posidx].x,new_ptr[posidx].y);
        if(posidx<dim)
        {
            cur_ptr[idx].x=new_ptr[posidx].x;
            cur_ptr[idx].y=new_ptr[posidx].y;
            lenVec[idx]=1;
        }
    }
    nextPtrs[idx].x=cur_ptr[idx].x;
    nextPtrs[idx].y=cur_ptr[idx].y;
}
__global__ void  makeGroupKernel(int* labelidx,Groups groups,TracksInfo trkinfo)
{
    int pidx=threadIdx.x;
    int gidx=blockIdx.x;
    int* idx_ptr=groups.trkPtsIdxPtr;
    int* count_ptr=groups.ptsNumPtr;
    int nFeatures=groups.trkPtsNum;
    int* cur_gptr = idx_ptr+gidx*nFeatures;
    FeatPts* cur_Trkptr=trkinfo.curTrkptr+pidx;
    float2* cur_veloPtr=trkinfo.curVeloPtr+pidx;
    float2* trkPtsPtr=groups.trkPtsPtr+gidx*nFeatures;
    __shared__ int counter;
    __shared__ float com[2],velo[2];
    __shared__ int left,right,top,bot;
    left=9999,right=0,top=9999,bot=0;
    com[0]=0,com[1]=0;
    velo[0]=0,velo[1]=0;
    counter=0;
    __syncthreads();
    if(labelidx[pidx]==gidx)
    {
        float x=cur_Trkptr->x,y=cur_Trkptr->y;
        int px=x+0.5,py=y+0.5;
        int pos=atomicAdd(&counter,1);
        cur_gptr[pos]=pidx;
        trkPtsPtr[pos].x=x;
        trkPtsPtr[pos].y=y;
        atomicAdd(com,x);
        atomicAdd((com+1),y);
        atomicAdd(velo,cur_veloPtr->x);
        atomicAdd((velo+1),cur_veloPtr->y);
        atomicMin(&left,px);
        atomicMin(&top,py);
        atomicMax(&right,px);
        atomicMax(&bot,py);
    }
    __syncthreads();
    count_ptr[gidx]=counter;
    groups.comPtr[gidx].x=com[0]/counter;
    groups.comPtr[gidx].y=com[1]/counter;
    groups.veloPtr[gidx].x=velo[0]/counter;
    groups.veloPtr[gidx].y=velo[1]/counter;
    groups.bBoxPtr[gidx*4]=left;
    groups.bBoxPtr[gidx*4+1]=top;
    groups.bBoxPtr[gidx*4+2]=right;
    groups.bBoxPtr[gidx*4+3]=bot;
}
__global__ void  groupProp(int* labelidx,Groups groups,TracksInfo trkinfo)
{

}
__host__ __device__ __forceinline__ float cross_(const cvxPnt& O, const cvxPnt& A, const cvxPnt &B)
{
    return (A.x - O.x) * (B.y - O.y) - (A.y - O.y) * (B.x - O.x);
}

__global__ void genPolygonKernel(Groups groups)
{
    int gidx=blockIdx.x;
    int nFeatures=groups.trkPtsNum;
    int count=groups.ptsNumPtr[gidx];
    const int* countPtr=groups.ptsNumPtr+gidx;
    cvxPnt* H=(cvxPnt*)groups.polygonPtr+gidx*nFeatures;
    cvxPnt* P=(cvxPnt*)groups.trkPtsPtr+gidx*nFeatures;

    int n = count, k = 0;
    thrust::sort(thrust::seq,P,P+count);
    // Build lower hull
    for (int i = 0; i < n; ++i) {
        while (k >= 2 && cross_(H[k-2], H[k-1], P[i]) <= 0) k--;
        H[k++]=P[i];
    }

    // Build upper hull
    for (int i = n-2, t = k+1; i >= 0; i--) {
        while (k >= t && cross_(H[k-2], H[k-1], P[i]) <= 0) k--;
        H[k++]=P[i];
    }
    groups.polyCountPtr[gidx]=k;
}
__global__ void matchGroupKernel(GroupTrack* groupsTrks,Groups* trkGroup)
{

}
void CrowdTracker::filterTrackGPU()
{
    trkInfo=tracksGPU->getInfoGPU();
    trkInfo.preTrkptr=trkInfo.getVec_(trkInfo.trkDataPtr,minTrkLen-1);
    /*
    filterTracks<<<1,nFeatures>>>(tracksGPU->cur_gpu_ptr,tracksGPU->next_gpu_ptr,(float2 *)gpuNextPts.data,
                                  tracksGPU->lendata->gpu_ptr(),gpuStatus.data,persMap->gpu_ptr(),
                                  tracksGPU->NQue,tracksGPU->buff_len,tracksGPU->tailidx);
    */
    filterTracks<<<1,nFeatures>>>(trkInfo,gpuStatus.data,(float2 *)gpuNextPts.data,persMap->gpu_ptr());
    tracksGPU->increPtr();
    trkInfo=tracksGPU->getInfoGPU();
    trkInfo.preTrkptr=trkInfo.getVec_(trkInfo.trkDataPtr,minTrkLen);
}

void CrowdTracker::findPoints()
{
    std::cout<<"applySegMask"<<std::endl;
    if(applyseg)
    {
        int nblocks = (frame_height*frame_width)/nFeatures;
        applySegMask<<<nblocks,nFeatures>>>(mask->gpu_ptr(),segmask->gpu_ptr(),segNeg->gpu_ptr());
    }
    std::cout<<"detector"<<std::endl;
    (*detector)(gpuGray, gpuCorners,maskMat);
}

void CrowdTracker::pointCorelate()
{
    clearLostStats<<<nFeatures,nFeatures>>>(tracksGPU->lenData->gpu_ptr(),
                                                         nbCount->gpu_ptr(),cosCo->gpu_ptr(),veloCo->gpu_ptr(),distCo->gpu_ptr(),nFeatures);

    searchNeighbor <<<nFeatures, nFeatures>>>(trkInfo,nbCount->gpu_ptr(),cosCo->gpu_ptr(),veloCo->gpu_ptr(),distCo->gpu_ptr(),persMap->gpu_ptr(), nFeatures);

}
inline void buildPolygon(float2* pts,int& ptsCount,float2* polygon,int& polyCount)
{
    cvxPnt* P=(cvxPnt*)pts;
    cvxPnt* H=(cvxPnt*)polygon;
    int n = ptsCount, k = 0;
    // Sort points lexicographically
    std::sort(P,P+ptsCount);
    // Build lower hull
    for (int i = 0; i < n; ++i) {
        while (k >= 2 && cross_(H[k-2], H[k-1], P[i]) <= 0) k--;
        H[k++]=P[i];
    }

    // Build upper hull
    for (int i = n-2, t = k+1; i >= 0; i--) {
        while (k >= t && cross_(H[k-2], H[k-1], P[i]) <= 0) k--;
        H[k++]=P[i];
    }
    polyCount=k;
}
void CrowdTracker::makeGroups()
{
    label->SyncH2D();
    prelabel->SyncH2D();
    groups->numGroups=groupN;
    makeGroupKernel<<<groupN,nFeatures>>>(label->gpu_ptr(),*groups,trkInfo);
    groups->SyncD2H();
    for(int i=1;i<=groupN;i++)
    {
        buildPolygon(groups->trkPts->cpu_ptr()+i*nFeatures,groups->ptsNum->cpu_ptr()[i]
                    ,groups->polygon->cpu_ptr()+i*nFeatures,groups->polyCount->cpu_ptr()[i]);
    }
    groups->polySyncH2D();
    //genPolygonKernel<<<nFeatures,1>>>(*groups);

}
void CrowdTracker::matchGroups()
{

    dim3 block(32, 32,1);

    dim3 grid(divUp(frame_width,32),divUp(frame_height,32),);
    /*
    for(int j=0;j<groups->numGroups;i++)
    {
        for(int i=0;i<groupsTrk->numGroup;i++)
        {
            matchGroupKernel(groupsTrk,groups);
        }
    }

    for(int i=0;i<groupN;i++)
    {
        groupsTrk->addGroups(groups,i);
    }
    */

}
void CrowdTracker::PersExcludeMask()
{


    addNewPts<<<1,nFeatures,0,cornerStream>>>(tracksGPU->curTrkptr,tracksGPU->lenVec,corners->gpu_ptr(),(float2* )gpuPrePts.data);


    std::cout<<"applyPersToMask:"<<std::endl;
    cudaMemcpyAsync(mask->gpu_ptr(),roimask->gpu_ptr(),frame_height*frame_width*sizeof(unsigned char),cudaMemcpyDeviceToDevice,cornerStream);
    dim3 block(32, 32,1);
    applyPointPersMask<<<nFeatures,block,0,cornerStream>>>(mask->gpu_ptr(),tracksGPU->curTrkptr,tracksGPU->lenVec,persMap->gpu_ptr());

    corners->SyncD2HStream(cornerStream);
}
void CrowdTracker::Render(unsigned char * framedata)
{
    int nblocks = (frame_height*frame_width)/nFeatures;
    renderFrame<<<nblocks,nFeatures>>>(mask->gpu_ptr(),rgbMat.data,frame_width*frame_height);
    cudaMemcpy(framedata,rgbMat.data,frame_height*frame_width*3*sizeof(unsigned char),cudaMemcpyDeviceToHost);
}


#include "Qts/viewqt.h"
#include "Qts/modelsqt.h"
#include "Qts/streamthread.h"

#include <iostream>
#include <stdio.h>

#include <QPainter>
#include <QBrush>
#include <QPixmap>
#include <cmath>
#include <QGraphicsSceneEvent>
#include <QMimeData>
#include <QByteArray>
#include <QFont>
char viewstrbuff[200];
QPointF points[100];

void DefaultScene::mousePressEvent ( QGraphicsSceneMouseEvent * event )
{
    emit clicked(event);
}
void DefaultScene::drawBackground(QPainter * painter, const QRectF & rect)
{
    QPen pen;
    QFont txtfont("Roman",40);
    txtfont.setBold(true);
    pen.setColor(QColor(255,255,255));
    pen.setCapStyle(Qt::RoundCap);
    pen.setJoinStyle(Qt::RoundJoin);
    pen.setWidth(10);
    painter->setPen(QColor(243,134,48,150));
    painter->setFont(txtfont);
    painter->drawText(rect, Qt::AlignCenter,"打开文件\nOpen File");
}
TrkScene::TrkScene(const QRectF & sceneRect, QObject * parent):QGraphicsScene(sceneRect, parent)
{
    streamThd=NULL;
}
TrkScene::TrkScene(qreal x, qreal y, qreal width, qreal height, QObject * parent):QGraphicsScene( x, y, width, height, parent)
{
    streamThd=NULL;
}
void TrkScene::drawBackground(QPainter * painter, const QRectF & rect)
{
    //std::cout<<streamThd->inited<<std::endl;
    if(streamThd!=NULL&&streamThd->inited)
    {
        updateFptr(streamThd->frameptr, streamThd->frameidx);
    }
    painter->setBrush(bgBrush);
    painter->drawRect(rect);
//    painter->setBrush(QColor(0,0,0,100));
//    painter->drawRect(rect);
    painter->setBrush(Qt::NoBrush);
    if(streamThd!=NULL&&streamThd->inited)
    {
        int* neighbor = streamThd->tracker->getNbCount();
        int nFeatures= streamThd->tracker->getNFeatures();
        int nSearch=streamThd->tracker->getNFeatures();
        float* distmat=streamThd->tracker->getDistCo();
        float* cosine=streamThd->tracker->getCosCo();
        float* velo=streamThd->tracker->getVeloCo();
        int* labelVec=streamThd->tracker->getLabel();
        unsigned char* clrvec=streamThd->tracker->getClrvec();
        float2* corners = streamThd->tracker->getCorners();

        linepen.setColor(QColor(255,200,200));
        linepen.setWidth(3);
        painter->setPen(linepen);
        painter->setFont(QFont("System",20,2));
        QString infoString="fps:"+QString::number(streamThd->fps)+"\n"
                +"use Seg:"+QString::number(streamThd->tracker->isSegOn())+"\n"
                +"Prop Idx:"+QString::number(showModeIdx)+"\n"
                +"thresh:"+QString::number(thresh)+"\n";
        painter->drawText(rect, Qt::AlignLeft|Qt::AlignTop,infoString);
        painter->setFont(QFont("System",20,2));
        Tracks* tracks = streamThd->tracker->getTracks();
        Groups* groups = streamThd->tracker->getGroups();
        GroupTracks& groupsTrk = streamThd->tracker->getGroupsTrk();
        float2* com = groups->com->cpu_ptr();
        float x0,y0,x1,y1;
        linepen.setWidth(2);
        for(int i=0;i<tracks->nQue&&false;i++)
        {
            int trklen = tracks->getLen(i);
            //std::cout<<trklen<<std::endl;
            int label=labelVec[i];
            unsigned char r=255,g=255,b=255;
            if(label)
            {
                r=clrvec[label*3],g=clrvec[label*3+1],b=clrvec[label*3+2];
            }
            if(trklen>0)
            {
                FeatPts* pg = tracks->getPtr(i);
                x1=pg->x,y1=pg->y;
                linepen.setColor(QColor(r, g, b));
                linepen.setWidth(2);
                painter->setPen(linepen);
                painter->drawPoint(x1,y1);
            }
            /*
            linepen.setColor(QColor(255, 128, 0));
            linepen.setWidth(2);
            painter->setPen(linepen);
            painter->drawPoint(corners[i].x,corners[i].y);
            painter->setFont(QFont("System",10,2));
            linepen.setColor(QColor(0,0,255));
            painter->setPen(linepen);
            */
            linepen.setWidth(0);
            /*
            if(trklen>minTrkLen)
            {
                int tailidx=tracks->tailidx,bufflen=tracks->buff_len,NQue=tracks->NQue  ;
                int offset = (tailidx+bufflen-minTrkLen)%bufflen;
                FeatPts* pre_ptr=tracks->trkdata->cpu_ptr()+NQue*offset;
                x0=pre_ptr[i].x,y0=pre_ptr[i].y;
                if(abs(x0-x1)>500)streamThd->pause=true;
                painter->drawLine(x1, y1, x0, y0);
            }
            */

            if(label)
            {
                for (int j = i+1; j < nFeatures; j++)
                {
                    if(label==labelVec[j])
                    {
                        FeatPts* pj = tracks->getPtr(j);
                        int xj = pj->x, yj = pj->y;
                        float val = -1;
                        val=neighbor[i*nFeatures+j];
                        //int xmid = (xj+x1)/2.0+0.5,ymid=(yj+y1)/2.0+0.5;
                        //float dist=distmat[i*nFeatures+j];
                        //int hdist = abs(xj-x1)+abs(yj-y1);
                        val=val/(val+10.0)*255;
                        if(val>0)
                        {
                            linepen.setColor(QColor(r,g,b,val));
                            painter->setPen(linepen);
                            painter->drawLine(x1, y1, xj, yj);
        //                    painter->drawText(xmid,ymid,QString::number(dist));
        //                    painter->drawText(x1,y1,QString::number(tracks->getLen(i)));
        //                    painter->drawText(xj,yj,QString::number(tracks->getLen(j)));
                        }
                    }
                }
            }
        }

        linepen.setWidth(2);
        linepen.setColor(QColor(255,255,255));
        painter->setPen(linepen);
        for(int i =0;i<groupsTrk.numGroup;i++)
        {
            if((*groupsTrk.vacancy)[i])
            {
                BBox* bbox = groupsTrk.getCurBBox(i);
                painter->drawRect(bbox->left,bbox->top,bbox->right-bbox->left,bbox->bottom-bbox->top);

            }
        }

        int* groupSize = groups->ptsNum->cpu_ptr();
        int* groupVec= groups->trkPtsIdx->cpu_ptr();
        float2* groupVelo=groups->velo->cpu_ptr();
        BBox* groupbBox=groups->bBox->cpu_ptr();

        for(int i=1;i<=groups->numGroups;i++)
        {

            int * idx_ptr=groupVec+nFeatures*i;
            unsigned char r=clrvec[i*3],g=clrvec[i*3+1],b=clrvec[i*3+2];
            linepen.setWidth(0);
            linepen.setColor(QColor(r,g,b,150));
            painter->setPen(linepen);
            for(int j=0;j<groupSize[i];j++)
            {
                int idx=idx_ptr[j];
                float x =tracks->getPtr(idx)->x,y=tracks->getPtr(idx)->y;
                painter->drawRect(x-3,y-3,5,5);
            }
            linepen.setColor(QColor(255,255,255));
            linepen.setWidth(2);
            painter->setPen(linepen);
            painter->drawText(com[i].x,com[i].y,QString::number(i));
            float dstx=com[i].x+groupVelo[i].x,dsty=com[i].y+groupVelo[i].y;
            linepen.setWidth(4);
            painter->setPen(linepen);
            painter->drawLine(com[i].x,com[i].y,dstx,dsty);
            linepen.setColor(QColor(0,0,0));
            linepen.setStyle(Qt::DashLine);
            painter->setPen(linepen);
            BBox& bb = groupbBox[i];
            painter->drawRect(bb.left,bb.top,bb.right-bb.left,bb.bottom-bb.top);
            linepen.setStyle(Qt::SolidLine);
            float2* polygon = groups->polygon->cpu_ptr()+i*nFeatures;
            int polyCount=groups->polyCount->cpu_ptr()[i];
            for(int j=1;j<polyCount;j++)
            {
                painter->drawLine(polygon[j-1].x,polygon[j-1].y,polygon[j].x,polygon[j].y);
            }
        }
    }

    //update();
    //views().at(0)->update();
}
void TrkScene::mousePressEvent(QGraphicsSceneMouseEvent *event)
{
    if(event->button()==Qt::RightButton)
    {
        int x = event->scenePos().x(),y=event->scenePos().y();
        DragBBox* newbb = new DragBBox(x-10,y-10,x+10,y+10);
        int pid = dragbbvec.size();
        newbb->bbid=pid;
        newbb->setClr(255,255,255);
        sprintf(newbb->txt,"%c\0",pid+'A');
        dragbbvec.push_back(newbb);
        addItem(newbb);
    }
    QGraphicsScene::mousePressEvent(event);
}
void TrkScene::updateFptr(unsigned char * fptr,int fidx)
{
    bgBrush.setTextureImage(QImage(fptr,streamThd->framewidth,streamThd->frameheight,QImage::Format_RGB888));
    frameidx=fidx;
    //std::cout<<frameidx<<std::endl;
}
void TrkScene::clear()
{
    bgBrush.setStyle(Qt::NoBrush);
}

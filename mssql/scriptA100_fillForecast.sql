
 -- amount of rules is required for probability 
  update fish      set numRuls=0
  update f set numRuls=1           FROM fish_Rule s, fish f WHERE s.tmL is not null AND  s.tmH is not null AND s.fish_Id=f.fish_Id
  update f set numRuls=2 | numRuls FROM fish_Rule s, fish f WHERE s.tuL is not null AND  s.tuH is not null AND s.fish_Id=f.fish_Id
  update f set numRuls=4 | numRuls FROM fish_Rule s, fish f WHERE s.oxL is not null AND  s.oxH is not null AND s.fish_Id=f.fish_Id
  GO
 -------------------------   create today data for currnt forecast  ---------------------------------------------
delete from CurrentWaterState 
GO 

--select * from CurrentWaterState where mli in (select mli from WaterStation where country='CA' and state='ON')
GO

 insert into CurrentWaterState 
   SELECT temperature, conductance, discharge, turbidity, oxygen, ph, elevation, sid, mli, stamp,  GETUTCDATE() as iterstamp
   FROM USWater.dbo.vUSWaterData WHERE sid in 
      ( SELECT MAX(sid) FROM USWater.dbo.vUSWaterData  WHERE stamp > '20140801' GROUP BY mli )

insert into CurrentWaterState 
   SELECT temperature, conductance, discharge, turbidity, oxygen, ph, elevation, sid, mli, stamp,  GETUTCDATE() as iterstamp
   FROM USWater.dbo.ONCA257 WHERE sid in 
      ( SELECT MAX(sid) FROM USWater.dbo.ONCA257  WHERE stamp > '20011101' GROUP BY mli )  
      AND mli not in (select mli from CurrentWaterState)    
       
GO
update t SET t.temperature=w.temperature, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.vUSWaterData w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND temperature IS NOT NULL GROUP BY mli   )
                             
update t SET t.temperature=w.temperature, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND temperature IS NOT NULL GROUP BY mli   )
                  
update t SET t.turbidity=w.turbidity, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.vUSWaterData w  WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData  WITH (NOLOCK) WHERE ( stamp > '20010101' )
                 AND turbidity IS NOT NULL GROUP BY mli )        
                       
update t SET t.turbidity=w.turbidity, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND turbidity IS NOT NULL GROUP BY mli   )

                 
update t SET t.oxygen=w.oxygen, t.stamp=w.stamp FROM CurrentWaterState t  WITH (NOLOCK), USWater.dbo.vUSWaterData w   WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData  WITH (NOLOCK) WHERE ( stamp > '20010101'  )
                 AND oxygen IS NOT NULL GROUP BY mli )         
    
update t SET t.oxygen=w.oxygen, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND oxygen IS NOT NULL GROUP BY mli   )
    
                      
update t SET t.conductance=w.conductance, t.stamp=w.stamp FROM CurrentWaterState t  WITH (NOLOCK), USWater.dbo.vUSWaterData w   WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData  WITH (NOLOCK) WHERE ( stamp > '20010101'  )
                 AND conductance IS NOT NULL GROUP BY mli ) 
        
update t SET t.conductance=w.conductance, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND conductance IS NOT NULL GROUP BY mli   )
                                  
update t SET t.discharge=w.discharge, t.stamp=w.stamp FROM CurrentWaterState t  WITH (NOLOCK) , USWater.dbo.vUSWaterData w  WITH (NOLOCK) 
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData  WITH (NOLOCK)  WHERE ( stamp > '20010101'  )
                 AND discharge IS NOT NULL GROUP BY mli ) 
      
update t SET t.discharge=w.discharge, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND discharge IS NOT NULL GROUP BY mli   )
                                 
update t SET t.ph=w.ph, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.vUSWaterData w  WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData WITH (NOLOCK) WHERE ( stamp > '20010101'  )
                 AND ph IS NOT NULL GROUP BY mli )    
                  
update t SET t.ph=w.ph, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND ph IS NOT NULL GROUP BY mli   )
                              
update t SET t.elevation=w.elevation, t.stamp=w.stamp 
  FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.vUSWaterData w WITH (NOLOCK) 
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.vUSWaterData WITH (NOLOCK) WHERE ( stamp > '20010101'  )
                 AND elevation IS NOT NULL GROUP BY mli )    
                 
update t SET t.elevation=w.elevation, t.stamp=w.stamp FROM CurrentWaterState t WITH (NOLOCK), USWater.dbo.ONCA257 w WITH (NOLOCK)
    WHERE t.mli=w.mli AND w.sid IN (
   SELECT MAX(sid) FROM USWater.dbo.ONCA257 WITH (NOLOCK) WHERE ( stamp > '20100101' ) AND elevation IS NOT NULL GROUP BY mli   )
                                  
GO

-------------------------   push today's forecast  ------------------------- --------------------
delete from fish_location 
GO
-- initial filling
insert into fish_location (station_Id,  fish_Id ) 
  select w.id as station_Id,  lf.fish_Id 
     from vWaterStation w
	   JOIN lake_fish        lf ON w.lakeId = lf.lake_Id
	   JOIN fish              g ON lf.fish_id = g.fish_id
	   JOIN CurrentWaterState r ON w.mli=r.mli
       WHERE  
--        AND w.state = 'ON' AND country = 'CA'
           ( ((1 & w.locType ) = 1 AND ( 1 & g.water_type ) = 1)     -- lives in lake
           OR  ((2 & w.locType ) = 2 AND ( 2 & g.water_type ) = 2)     -- lives in river
           OR  ((4 & w.locType ) = 4 AND ( 4 & g.water_type ) = 4)     -- lives in stream
           OR  ((8 & w.locType ) = 8 AND ( 8 & g.water_type ) = 8)     -- lives in ponds
           OR  ((16 & w.locType ) = 16 AND ( 16 & g.water_type ) = 16) -- lives in marsh
           OR  ((32 & w.locType ) = 32 AND ( 32 & g.water_type ) = 32)  -- lives in backwater
           OR  ((64 & w.locType ) = 64 AND ( 64 & g.water_type ) = 64)        -- lives in creek
           OR  ((128 & w.locType )= 128 AND ( 128 & g.water_type ) = 128)     -- lives in canal
           OR  ((256 & w.locType )= 256 AND ( 256 & g.water_type ) = 256)     -- lives in Estuary
           OR  ((512 & w.locType )= 512 AND ( 512 & g.water_type ) = 512)     -- lives in shore
           OR  ((1024 & w.locType )= 1024 AND ( 1024 & g.water_type ) = 1024) -- lives in drain
--           OR  ((2048 & w.locType )= 2048 AND ( 2048 & f.water_type ) = 2048) -- lives in ocean
           OR  ((4096 & w.locType )= 4096 AND ( 4096 & g.water_type ) = 4096)-- lives in Wetland
--           OR  ((8192 & w.locType )= 8192 AND ( 8192 & f.habitat ) = 8192)-- lives in Reservoir
           OR  ((16384 & w.locType )= 16384 AND ( 16384 & g.water_type ) = 16384)-- lives in Dam
           OR  ((32768 & w.locType )= 32768 AND ( 32768 & g.water_type ) = 32768))-- lives in falls
         AND EXISTS (SELECT *  FROM fish_Rule r WHERE g.fish_Id=r.fish_Id)    -- AND f.water <> 1
GO
 ---- 1 - temperature, 2 - turbidity, 4 - oxygen 
 select * from vWaterStation

-- EXEC dbo.spPushSpeciesFromLakeToStation

-- select * from vGetFishingStation100TmTu
--select MAX(temperature), MIN(temperature) from CurrentWaterState
--select * from CurrentWaterState


--select * from vGetFishingStation100Tm
--select * from vFishRulesTm


--select * from vGetFishingStation100Tu
--select * from vFishRulesTmTu
--select * from  dbo.SpeciesRules where fishid in (select ID from dbo.Species where name='Lake Chubsucker')
--update SpeciesRules set tuL = NULL, tuH=NULL where fishid in (select ID from dbo.Species where name='Bull trout')


-------------------------------------  distance  -----------------------------------
-- dbo.sp_weather_forecast16 was defined here (a copy older than the one that lived in
-- script02_Proc.sql - it still wrote the long-gone maxWin / degree / direction / weather_temperature
-- columns). Retired 2026-08-11 with the script02_Proc.sql copy; see that file for why.

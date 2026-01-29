library(rvest)
library(httr)
library(jsonlite)
library(dplyr)
library(readr)
library(purrr)
library(stringr)
library(xml2)


# Paths for checkpointing
results_file <- "iNaturalist_identification.RData"
denied_file  <- "Permission_denied_iNat.csv"
plant_file <- "iNaturalist_host_plants.csv"
batch_size   <- 200  # process 500 obs per batch to avoid overload

# API key
api_key <- "2b10bu236VtELMT8bV13UQb73e"

# Load your observation data
obs <- read_csv("../Data/Observation/iNaturalist_bees.csv", show_col_types = FALSE)
photos <- read_csv("../Data/Observation/iNaturalist_photos.csv", show_col_types = FALSE)

# Load previous results if they exist
if (file.exists(results_file)) results_list <- readRDS(results_file) else results_list <- list()
if (file.exists(denied_file)) permission_denied <- read_csv(denied_file, show_col_types = FALSE) else permission_denied <- data.frame(denied = numeric())
if (file.exists(plant_file)) host_plants <- read_csv(plant_file, show_col_types = FALSE) else host_plants <- data.frame(observation__uuid = character(), plant = character())

already_identified <- c(names(results_list), permission_denied$denied)
id_pol_all <- unique(obs$observation_uuid)
id_pol <- setdiff(id_pol_all, already_identified)

buildURL <- function(key, imageURL, organs = 'auto', lang = 'en', no_reject = 'true'){
  URLencoded <- sapply(imageURL, FUN = URLencode, reserved = TRUE, repeated = TRUE)
  paste0(
    "https://my-api.plantnet.org/v2/identify/all?",
    "images=", paste(URLencoded, collapse = "&images="),
    "&organs=", paste(organs, collapse = "&organs="),
    "&no-reject=", no_reject,
    "&lang=", lang,
    "&api-key=", key
  )
}

# test id
id <- photos$observation_uuid[1]
id <- "7abe4034-d427-41e7-aed8-3af34a654248"
# test id for taking also plant
id <- photos$observation_uuid[photos$photo_id == 1390299]

process_one_id_inat <- function(id, photos, api_key){
  
  imageURL <- photos$photo_id[photos$observation_uuid == id]
  imageURL <- unique(imageURL)
  image_type <- photos$extension[photos$observation_uuid == id]
  image_urls <- paste("https://inaturalist-open-data.s3.amazonaws.com/photos/", imageURL, "/original.", image_type, sep="")
  
  # check URL for plant images
  plant_URL <- paste("https://www.inaturalist.org/photos/", imageURL, sep="")
  
  # assess page
  page <- read_html(plant_URL[1]) 
  
  # get table
  tables <- page %>% html_table()
  tables <- tables[[2]]
  tables <- tables[tables$X1 %in% c("Associated observations"),]

  # retrieve species names (are normally between brackets)
  taxa <- str_extract_all(tables$X2,"\\([A-Z][a-z]+\\s+[×x]?\\s*[a-z]+(?:\\s+[a-z]+)?\\)")[[1]] |> str_remove_all("[()]") |> str_squish()
  # remove the pollinator species
  taxa <- taxa[!taxa %in% obs$name[obs$observation_uuid== id]]
  
  if(length(taxa > 0)){
    data <- data.frame(observation__uuid = id, plant = taxa)
    host_plants <- rbind(host_plants, data)
    write_csv(host_plants, plant_file)
  }
  
  if (length(image_urls) < 1) return(list(id = id, denied = TRUE, result = NULL))
  
  results_pol <- list()
  results_pol_organs <- list()
  
  chunks <- ceiling(length(image_urls)/5)
  
  for (chunk in seq_len(chunks)) {
    length_chunks <- ceiling(length(image_urls)/chunks)
    min_chunk <- (chunk-1)*length_chunks + 1
    max_chunk <- min(chunk*length_chunks, length(image_urls))
    picturesURL <- image_urls[min_chunk:max_chunk]
    
    URL <- buildURL(api_key, picturesURL, organs = rep("auto", length(picturesURL)), lang = "en", no_reject = "true")
    
    response <- tryCatch(httr::GET(URL), error = function(e) NULL)
    
    if (is.null(response) || response$status_code != 200) next
    
    parsed_result <- fromJSON(content(response, "text"), flatten = TRUE)
    
    predicted_organ <- parsed_result$predictedOrgans[,2:3]
    predicted_organ <- cbind(ID = id, predicted_organ, imageURL = picturesURL)
    predicted_plant <- cbind(ID = id, parsed_result$results)
    
    results_pol[[length(results_pol) + 1]] <- predicted_plant
    results_pol_organs[[length(results_pol_organs) + 1]] <- predicted_organ
    
    Sys.sleep(0.2)  # small delay to reduce throttling
  }
  
  if (length(results_pol) == 0 && length(results_pol_organs) == 0) return(list(id = id, denied = TRUE, result = NULL))
  
  results_pol <- bind_rows(results_pol)
  results_pol_organs <- bind_rows(results_pol_organs)
  
  list(id = id, denied = FALSE, result = list(predicted_plant = results_pol, predicted_organ = results_pol_organs))
}

total_ids <- length(id_pol)
batches <- split(id_pol, ceiling(seq_along(id_pol)/batch_size))
batches <- batches[1:5]

begin <- Sys.time()

for (b in seq_along(batches)) {
  batch_ids <- batches[[b]]
  message("Processing batch ", b, " of ", length(batches), " (", length(batch_ids), " observations) at ", Sys.time())
  
  batch_results <- lapply(batch_ids, process_one_id_inat, photos=photos, api_key=api_key)
  
  # Update results
  for (res in batch_results) {
    if (res$denied) {
      permission_denied <- bind_rows(permission_denied, data.frame(denied = res$id))
    } else {
      results_list[[as.character(res$id)]] <- res$result
    }
  }
  
  # Checkpoint after every batch
  saveRDS(results_list, results_file)
  write_csv(permission_denied, denied_file)
  
  gc()
  Sys.sleep(2)
}
end <- Sys.time()
end-begin
